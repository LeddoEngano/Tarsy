using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Terminal;

/// <summary>
/// Dedicated Claude Code session — mirrors macOS ClaudeCodeSession.
/// Uses stream-json input/output format for structured communication.
/// Tracks tokens and handles permission protocol.
/// </summary>
public class ClaudeCodeSession : IAIEngine
{
    public string SessionId { get; }
    public string EngineName => "claude_code";
    public bool IsRunning => _process is { HasExited: false };

    private Process? _process;
    private CancellationTokenSource? _cts;
    private readonly Action<string, string> _onOutput; // (sessionId, jsonLine)
    private readonly Action<string> _onComplete; // (sessionId)
    private readonly Action<string, string> _onAskUser; // (sessionId, questionJson)

    public int InputTokens { get; private set; }
    public int OutputTokens { get; private set; }

    public ClaudeCodeSession(
        string sessionId,
        Action<string, string> onOutput,
        Action<string> onComplete,
        Action<string, string> onAskUser)
    {
        SessionId = sessionId;
        _onOutput = onOutput;
        _onComplete = onComplete;
        _onAskUser = onAskUser;
    }

    public async Task Start(string workingDirectory, string? model = null)
    {
        var claudePath = FindClaudeBinary();
        if (claudePath == null)
            throw new FileNotFoundException("Claude Code binary not found");

        _cts = new CancellationTokenSource();

        var args = new StringBuilder("-p --input-format stream-json --output-format stream-json --verbose");
        if (model != null)
            args.Append($" --model {model}");

        _process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = claudePath,
                Arguments = args.ToString(),
                WorkingDirectory = workingDirectory,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            }
        };

        // Enrich PATH
        _process.StartInfo.Environment["PATH"] = PathEnrichment.GetEnrichedPath();

        _process.Start();

        // Read NDJSON output
        _ = ReadNdjsonOutput(_process.StandardOutput, _cts.Token);
        _ = ReadStderr(_process.StandardError, _cts.Token);

        // Monitor exit
        _ = Task.Run(async () =>
        {
            try { await _process.WaitForExitAsync(_cts.Token); }
            catch (OperationCanceledException) { }
            finally { _onComplete(SessionId); }
        });

        Console.WriteLine($"[ClaudeCode] Started session {SessionId} in {workingDirectory}");
    }

    public async Task SendMessage(string message)
    {
        if (_process is not { HasExited: false }) return;

        var json = JsonSerializer.Serialize(new
        {
            type = "user_message",
            message,
        });

        await _process.StandardInput.WriteLineAsync(json);
        await _process.StandardInput.FlushAsync();
    }

    public async Task RespondToQuestion(string response)
    {
        if (_process is not { HasExited: false }) return;

        var json = JsonSerializer.Serialize(new
        {
            type = "control_response",
            response,
        });

        await _process.StandardInput.WriteLineAsync(json);
        await _process.StandardInput.FlushAsync();
    }

    public void Interrupt()
    {
        if (_process is { HasExited: false })
        {
            try
            {
                _process.StandardInput.Write('\x03');
                _process.StandardInput.Flush();
            }
            catch { }
        }
    }

    public void Terminate()
    {
        try
        {
            _cts?.Cancel();
            if (_process is { HasExited: false })
            {
                _process.Kill(entireProcessTree: true);
            }
        }
        catch { }
    }

    public void Dispose()
    {
        Terminate();
        _process?.Dispose();
        _cts?.Dispose();
    }

    // ── Output parsing ──

    private async Task ReadNdjsonOutput(StreamReader reader, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var line = await reader.ReadLineAsync(ct);
                if (line == null) break; // EOF

                if (string.IsNullOrWhiteSpace(line)) continue;

                try
                {
                    using var doc = JsonDocument.Parse(line);
                    var root = doc.RootElement;
                    var type = root.TryGetProperty("type", out var t) ? t.GetString() : null;

                    // Track tokens
                    if (root.TryGetProperty("usage", out var usage))
                    {
                        if (usage.TryGetProperty("input_tokens", out var inp))
                            InputTokens += inp.GetInt32();
                        if (usage.TryGetProperty("output_tokens", out var outp))
                            OutputTokens += outp.GetInt32();
                    }

                    // Check for permission request
                    if (type == "control_request")
                    {
                        _onAskUser(SessionId, line);
                        continue;
                    }
                }
                catch { /* not valid JSON, forward as raw output */ }

                _onOutput(SessionId, line);
            }
        }
        catch (OperationCanceledException) { }
        catch { /* reader closed */ }
    }

    private async Task ReadStderr(StreamReader reader, CancellationToken ct)
    {
        try
        {
            var buffer = new char[4096];
            while (!ct.IsCancellationRequested)
            {
                var count = await reader.ReadAsync(buffer, 0, buffer.Length);
                if (count == 0) break;
                // Stderr goes to console for debugging, not forwarded to client
                Console.Write($"[ClaudeCode:stderr] {new string(buffer, 0, count)}");
            }
        }
        catch { }
    }

    // ── Binary detection ──

    private static string? FindClaudeBinary()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        string[] candidates =
        {
            Path.Combine(home, ".claude", "bin", "claude.exe"),
            Path.Combine(appData, "npm", "claude.cmd"),
            Path.Combine(localAppData, "pnpm", "claude.cmd"),
            Path.Combine(home, ".bun", "bin", "claude.exe"),
            Path.Combine(home, ".volta", "bin", "claude.exe"),
        };

        foreach (var path in candidates)
        {
            if (File.Exists(path)) return path;
        }

        // Fallback: where.exe
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "where.exe",
                    Arguments = "claude",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }
            };
            process.Start();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(5000);

            var firstLine = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();
            if (firstLine != null && File.Exists(firstLine)) return firstLine;
        }
        catch { }

        return null;
    }
}
