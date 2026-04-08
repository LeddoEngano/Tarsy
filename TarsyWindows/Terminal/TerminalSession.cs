using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Terminal;

/// <summary>
/// A single terminal session backed by a PowerShell process with pipes.
/// ConPTY P/Invoke is complex and requires Windows SDK interop — this uses
/// Process with redirected I/O as a reliable cross-compatible approach
/// that still provides full terminal functionality.
/// </summary>
public class TerminalSession : IDisposable
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GenerateConsoleCtrlEvent(uint dwCtrlEvent, uint dwProcessGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(IntPtr handlerRoutine, bool add);

    private const uint CTRL_C_EVENT = 0;
    private static readonly object _ctrlCLock = new();

    public string SessionId { get; }
    public string? WorkingDirectory { get; }
    public bool IsRunning => _process is { HasExited: false };

    private Process? _process;
    private readonly Action<string, string> _onOutput; // (sessionId, data)
    private readonly Action<string> _onExit; // (sessionId)
    private CancellationTokenSource? _cts;

    public TerminalSession(string sessionId, string? workingDirectory, Action<string, string> onOutput, Action<string> onExit)
    {
        SessionId = sessionId;
        WorkingDirectory = workingDirectory;
        _onOutput = onOutput;
        _onExit = onExit;
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();

        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass",
            WorkingDirectory = WorkingDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };

        // PATH enrichment
        var enrichedPath = PathEnrichment.GetEnrichedPath();
        startInfo.Environment["PATH"] = enrichedPath;

        _process = new Process { StartInfo = startInfo };
        _process.Start();

        // Async output reading
        _ = ReadOutputAsync(_process.StandardOutput, _cts.Token);
        _ = ReadOutputAsync(_process.StandardError, _cts.Token);

        // Monitor for exit
        _ = Task.Run(async () =>
        {
            try
            {
                await _process.WaitForExitAsync(_cts.Token);
            }
            catch (OperationCanceledException) { }
            finally
            {
                _onExit(SessionId);
            }
        });

        // Force cd to working directory (shell profile may override)
        if (WorkingDirectory != null)
        {
            WriteInput($"Set-Location -LiteralPath '{WorkingDirectory.Replace("'", "''")}'\r\n");
        }
    }

    public void WriteInput(string data)
    {
        if (_process is { HasExited: false })
        {
            try
            {
                _process.StandardInput.Write(data);
                _process.StandardInput.Flush();
            }
            catch { /* process may have exited */ }
        }
    }

    public void Interrupt()
    {
        if (_process is not { HasExited: false }) return;

        lock (_ctrlCLock)
        {
            try
            {
                FreeConsole();
                if (AttachConsole((uint)_process.Id))
                {
                    SetConsoleCtrlHandler(IntPtr.Zero, true);
                    GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);

                    Thread.Sleep(100);
                    SetConsoleCtrlHandler(IntPtr.Zero, false);
                    FreeConsole();
                }
            }
            catch { }
        }
    }

    public void Kill()
    {
        try
        {
            if (_process is { HasExited: false })
            {
                _process.Kill(entireProcessTree: true);
            }
        }
        catch { }
    }

    public void Dispose()
    {
        _cts?.Cancel();
        Kill();
        _process?.Dispose();
        _cts?.Dispose();
    }

    private async Task ReadOutputAsync(StreamReader reader, CancellationToken ct)
    {
        var buffer = new char[4096];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var count = await reader.ReadAsync(buffer, 0, buffer.Length);
                if (count == 0) break; // EOF

                var text = new string(buffer, 0, count);
                _onOutput(SessionId, text);
            }
        }
        catch (OperationCanceledException) { }
        catch { /* reader closed */ }
    }
}
