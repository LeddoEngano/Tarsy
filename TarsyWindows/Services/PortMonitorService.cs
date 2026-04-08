using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using TarsyWindows.Terminal;

namespace TarsyWindows.Services;

/// <summary>
/// Port scanning, dev server start/stop, and process tree management.
/// Mirrors macOS PortMonitorService.
/// </summary>
public class PortMonitorService : IDisposable
{
    // ── Dev Server Tracking ──

    public record DevServerEntry(
        string SessionId,
        string WorkspacePath,
        string Command,
        int? DetectedPort,
        int? ProcessId,
        string State // "starting", "running", "stopped", "error"
    );

    private readonly ConcurrentDictionary<string, DevServerEntry> _devServers = new();
    private readonly SemaphoreSlim _startLock = new(1, 1);

    // Callbacks
    private readonly Action<string, string> _onOutput; // (workspacePath, data)
    private readonly Action<string, int?, string> _onStateChanged; // (workspacePath, port, state)

    // ── Allowlists ──

    private static readonly HashSet<string> AllowedRunners = new(StringComparer.OrdinalIgnoreCase)
    {
        "npm", "npx", "pnpm", "yarn", "bun", "node", "deno",
        "python", "python3", "ruby", "cargo", "go", "make",
        "docker", "gradle", "dotnet", "php", "uvicorn", "gunicorn",
    };

    private static readonly Regex[] ReadyPatterns = new[]
    {
        new Regex(@"ready on\s", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new Regex(@"listening on\s", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new Regex(@"localhost:\d+", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new Regex(@"compiled successfully", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new Regex(@"Local:\s+http", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new Regex(@"Network:\s+http", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new Regex(@"VITE\s+v\d", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new Regex(@"started server on", RegexOptions.IgnoreCase | RegexOptions.Compiled),
        new Regex(@"webpack compiled", RegexOptions.IgnoreCase | RegexOptions.Compiled),
    };

    private static readonly Regex PortExtractRegex = new(
        @"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|::1?):(\d{2,5})",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private TerminalSessionManager? _terminals;

    public PortMonitorService(
        Action<string, string> onOutput,
        Action<string, int?, string> onStateChanged)
    {
        _onOutput = onOutput;
        _onStateChanged = onStateChanged;
    }

    public void SetTerminalManager(TerminalSessionManager terminals)
    {
        _terminals = terminals;
    }

    // ════════════════════════════════════════════════
    // ── Port Scanning (W14.1) ──
    // ════════════════════════════════════════════════

    /// <summary>
    /// Scan listening TCP ports via netstat, return structured port list.
    /// </summary>
    public static async Task<List<Dictionary<string, string>>> DetectPorts()
    {
        var ports = new List<Dictionary<string, string>>();

        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = "netstat.exe",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            process.StartInfo.ArgumentList.Add("-ano");
            process.StartInfo.ArgumentList.Add("-p");
            process.StartInfo.ArgumentList.Add("TCP");

            process.Start();
            var output = await process.StandardOutput.ReadToEndAsync();

            using var cts = new CancellationTokenSource(5000);
            await process.WaitForExitAsync(cts.Token);

            // Parse netstat output
            var lines = output.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            var pidProcessCache = new Dictionary<int, string>();

            foreach (var line in lines)
            {
                var trimmed = line.Trim();
                if (!trimmed.Contains("LISTENING", StringComparison.OrdinalIgnoreCase))
                    continue;

                // Format: TCP    0.0.0.0:3000    0.0.0.0:0    LISTENING    12345
                var parts = trimmed.Split(Array.Empty<char>(), StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 5) continue;

                var localAddr = parts[1];
                var colonIdx = localAddr.LastIndexOf(':');
                if (colonIdx < 0) continue;

                var portStr = localAddr[(colonIdx + 1)..];
                if (!int.TryParse(portStr, out var port)) continue;
                if (port == 0) continue;

                var pidStr = parts[^1];
                if (!int.TryParse(pidStr, out var pid)) continue;

                // Resolve PID to process name
                if (!pidProcessCache.TryGetValue(pid, out var processName))
                {
                    processName = GetProcessName(pid);
                    pidProcessCache[pid] = processName;
                }

                var addr = localAddr[..colonIdx];

                ports.Add(new Dictionary<string, string>
                {
                    ["port"] = port.ToString(),
                    ["pid"] = pid.ToString(),
                    ["process"] = processName,
                    ["address"] = addr,
                });
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[PortMonitor] DetectPorts error: {ex.Message}");
        }

        // Deduplicate by port (keep first)
        return ports
            .GroupBy(p => p["port"])
            .Select(g => g.First())
            .OrderBy(p => int.Parse(p["port"]))
            .ToList();
    }

    private static string GetProcessName(int pid)
    {
        try
        {
            using var proc = Process.GetProcessById(pid);
            return proc.ProcessName;
        }
        catch
        {
            return "unknown";
        }
    }

    // ════════════════════════════════════════════════
    // ── Dev Server Start/Stop (W14.2) ──
    // ════════════════════════════════════════════════

    /// <summary>
    /// Start a dev server for the given workspace.
    /// </summary>
    public async Task<(bool success, string message, string? sessionId)> StartDevServer(
        string workspacePath, string command)
    {
        // Validate command runner
        var runner = command.Split(' ', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        if (!AllowedRunners.Contains(runner))
            return (false, $"Command runner '{runner}' not allowed", null);

        // Check if already running
        if (_devServers.Values.Any(d => d.WorkspacePath == workspacePath && d.State is "running" or "starting"))
            return (false, "Dev server already running for this workspace", null);

        if (_terminals == null)
            return (false, "Terminal manager not initialized", null);

        await _startLock.WaitAsync();
        try
        {
            var sessionId = _terminals.Create(workspacePath);
            var entry = new DevServerEntry(sessionId, workspacePath, command, null, null, "starting");
            _devServers[workspacePath] = entry;

            // Send the command
            _terminals.SendInput(sessionId, command + "\r\n");

            _onStateChanged(workspacePath, null, "starting");

            // Start monitoring for ready signal in background
            _ = MonitorReadySignal(workspacePath, sessionId);

            return (true, "Dev server starting", sessionId);
        }
        finally
        {
            _startLock.Release();
        }
    }

    /// <summary>
    /// Stop the dev server for the given workspace.
    /// </summary>
    public async Task<(bool success, string message)> StopDevServer(string workspacePath)
    {
        if (!_devServers.TryGetValue(workspacePath, out var entry))
            return (false, "No dev server found for this workspace");

        try
        {
            // Send Ctrl+C first
            if (_terminals != null)
                _terminals.Interrupt(entry.SessionId);

            // Wait 500ms for graceful shutdown
            await Task.Delay(500);

            // Kill the terminal session
            if (_terminals != null)
                _terminals.Close(entry.SessionId);

            // If we have a PID, kill the process tree
            if (entry.ProcessId.HasValue)
                await KillProcessTree(entry.ProcessId.Value);

            // If we have a port, verify it's freed (single scan)
            if (entry.DetectedPort.HasValue)
            {
                await Task.Delay(200);
                var ports = await DetectPorts();
                var portEntry = ports.FirstOrDefault(p => p["port"] == entry.DetectedPort.Value.ToString());
                if (portEntry != null && int.TryParse(portEntry["pid"], out var portPid))
                    await KillProcessTree(portPid);
            }

            _devServers.TryRemove(workspacePath, out _);
            _onStateChanged(workspacePath, entry.DetectedPort, "stopped");
            return (true, "Dev server stopped");
        }
        catch (Exception ex)
        {
            _devServers.TryRemove(workspacePath, out _);
            _onStateChanged(workspacePath, entry.DetectedPort, "error");
            return (false, $"Error stopping dev server: {ex.Message}");
        }
    }

    /// <summary>
    /// Get the status of a dev server.
    /// </summary>
    public Dictionary<string, string>? GetDevServerStatus(string workspacePath)
    {
        if (!_devServers.TryGetValue(workspacePath, out var entry))
            return null;

        return new Dictionary<string, string>
        {
            ["sessionId"] = entry.SessionId,
            ["command"] = entry.Command,
            ["port"] = entry.DetectedPort?.ToString() ?? "",
            ["state"] = entry.State,
            ["pid"] = entry.ProcessId?.ToString() ?? "",
        };
    }

    /// <summary>
    /// List all tracked dev servers.
    /// </summary>
    public List<Dictionary<string, string>> ListDevServers()
    {
        return _devServers.Values.Select(e => new Dictionary<string, string>
        {
            ["workspacePath"] = e.WorkspacePath,
            ["sessionId"] = e.SessionId,
            ["command"] = e.Command,
            ["port"] = e.DetectedPort?.ToString() ?? "",
            ["state"] = e.State,
        }).ToList();
    }

    // ── Ready signal monitoring ──

    private async Task MonitorReadySignal(string workspacePath, string sessionId)
    {
        // Wait up to 30s for a ready signal
        var timeout = DateTime.UtcNow.AddSeconds(30);

        while (DateTime.UtcNow < timeout)
        {
            if (!_devServers.TryGetValue(workspacePath, out var entry) || entry.State != "starting")
                return;

            await Task.Delay(500);
        }

        // Timeout — try port scanning as fallback
        if (_devServers.TryGetValue(workspacePath, out var e) && e.State == "starting")
        {
            var ports = await DetectPorts();
            // Look for common dev ports
            var devPort = ports.FirstOrDefault(p =>
            {
                var port = int.Parse(p["port"]);
                return port >= 3000 && port <= 9999;
            });

            if (devPort != null)
            {
                var port = int.Parse(devPort["port"]);
                UpdateDevServerState(workspacePath, port, "running");
            }
            else
            {
                UpdateDevServerState(workspacePath, null, "running");
            }
        }
    }

    /// <summary>
    /// Called by DaemonManager when terminal output contains a ready signal.
    /// </summary>
    public void CheckOutputForReadySignal(string sessionId, string output)
    {
        var entry = _devServers.Values.FirstOrDefault(d => d.SessionId == sessionId);
        if (entry == null || entry.State != "starting") return;

        // Check for ready patterns
        foreach (var pattern in ReadyPatterns)
        {
            if (pattern.IsMatch(output))
            {
                // Extract port
                var portMatch = PortExtractRegex.Match(output);
                int? port = portMatch.Success && int.TryParse(portMatch.Groups[1].Value, out var p) ? p : null;

                UpdateDevServerState(entry.WorkspacePath, port, "running");
                return;
            }
        }
    }

    private void UpdateDevServerState(string workspacePath, int? port, string state)
    {
        if (_devServers.TryGetValue(workspacePath, out var entry))
        {
            var updated = entry with { DetectedPort = port ?? entry.DetectedPort, State = state };
            _devServers[workspacePath] = updated;
            _onStateChanged(workspacePath, updated.DetectedPort, state);
            Console.WriteLine($"[PortMonitor] {workspacePath}: {state}, port={updated.DetectedPort}");
        }
    }

    // ════════════════════════════════════════════════
    // ── Process Tree Termination (W14.3) ──
    // ════════════════════════════════════════════════

    /// <summary>
    /// Kill a process and its entire process tree.
    /// </summary>
    public static async Task KillProcessTree(int pid)
    {
        try
        {
            using var process = new Process();
            process.StartInfo = new ProcessStartInfo
            {
                FileName = "taskkill.exe",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            process.StartInfo.ArgumentList.Add("/F");
            process.StartInfo.ArgumentList.Add("/T");
            process.StartInfo.ArgumentList.Add("/PID");
            process.StartInfo.ArgumentList.Add(pid.ToString());

            process.Start();

            using var cts = new CancellationTokenSource(5000);
            await process.WaitForExitAsync(cts.Token);

            Console.WriteLine($"[PortMonitor] Killed process tree PID {pid}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[PortMonitor] KillProcessTree error for PID {pid}: {ex.Message}");

            // Fallback: try direct kill
            try
            {
                using var proc = Process.GetProcessById(pid);
                proc.Kill(entireProcessTree: true);
            }
            catch { }
        }
    }

    // ── Helpers ──

    private static async Task<bool> IsPortInUse(int port)
    {
        var ports = await DetectPorts();
        return ports.Any(p => p["port"] == port.ToString());
    }

    private static async Task<int?> GetPidForPort(int port)
    {
        var ports = await DetectPorts();
        var entry = ports.FirstOrDefault(p => p["port"] == port.ToString());
        if (entry != null && int.TryParse(entry["pid"], out var pid))
            return pid;
        return null;
    }

    public void Dispose()
    {
        foreach (var (path, entry) in _devServers)
        {
            try
            {
                _terminals?.Close(entry.SessionId);
                if (entry.ProcessId.HasValue)
                    _ = KillProcessTree(entry.ProcessId.Value);
            }
            catch { }
        }
        _devServers.Clear();
        _startLock.Dispose();
    }
}
