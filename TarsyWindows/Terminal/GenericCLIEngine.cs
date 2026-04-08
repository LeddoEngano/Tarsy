using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Terminal;

/// <summary>
/// Generic CLI engine for Gemini, Codex, Aider, and custom agents.
/// Mirrors macOS GenericCLIEngine — wraps any CLI tool with standard I/O.
/// </summary>
public class GenericCLIEngine : IAIEngine
{
    public string SessionId { get; }
    public string EngineName { get; }
    public bool IsRunning => _process is { HasExited: false };

    private Process? _process;
    private CancellationTokenSource? _cts;
    private readonly string _binaryPath;
    private readonly string[] _defaultArgs;
    private readonly Action<string, string> _onOutput; // (sessionId, text)
    private readonly Action<string> _onComplete; // (sessionId)

    public GenericCLIEngine(
        string sessionId,
        string engineName,
        string binaryPath,
        string[] defaultArgs,
        Action<string, string> onOutput,
        Action<string> onComplete)
    {
        SessionId = sessionId;
        EngineName = engineName;
        _binaryPath = binaryPath;
        _defaultArgs = defaultArgs;
        _onOutput = onOutput;
        _onComplete = onComplete;
    }

    public async Task Start(string workingDirectory, string? model = null)
    {
        if (!File.Exists(_binaryPath))
            throw new FileNotFoundException($"{EngineName} binary not found at {_binaryPath}");

        _cts = new CancellationTokenSource();

        var args = string.Join(' ', _defaultArgs);
        if (model != null)
            args += $" --model {model}";

        _process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = _binaryPath,
                Arguments = args,
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

        _process.StartInfo.Environment["PATH"] = PathEnrichment.GetEnrichedPath();

        _process.Start();

        _ = ReadOutputAsync(_process.StandardOutput, _cts.Token);
        _ = ReadOutputAsync(_process.StandardError, _cts.Token);

        _ = Task.Run(async () =>
        {
            try { await _process.WaitForExitAsync(_cts.Token); }
            catch (OperationCanceledException) { }
            finally { _onComplete(SessionId); }
        });

        Console.WriteLine($"[{EngineName}] Started session {SessionId} in {workingDirectory}");
    }

    public async Task SendMessage(string message)
    {
        if (_process is not { HasExited: false }) return;

        await _process.StandardInput.WriteLineAsync(message);
        await _process.StandardInput.FlushAsync();
    }

    public async Task RespondToQuestion(string response)
    {
        // Generic engines use stdin for all input
        await SendMessage(response);
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

    private async Task ReadOutputAsync(StreamReader reader, CancellationToken ct)
    {
        var buffer = new char[4096];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var count = await reader.ReadAsync(buffer, 0, buffer.Length);
                if (count == 0) break;
                _onOutput(SessionId, new string(buffer, 0, count));
            }
        }
        catch (OperationCanceledException) { }
        catch { }
    }

    /// <summary>
    /// Factory: create engine instance for a known agent type.
    /// </summary>
    public static GenericCLIEngine? CreateForAgent(
        string sessionId,
        string engineType,
        string binaryPath,
        Action<string, string> onOutput,
        Action<string> onComplete)
    {
        var (name, args) = engineType switch
        {
            "gemini" => ("Gemini CLI", new[] { "--interactive" }),
            "codex" => ("Codex CLI", new[] { "--interactive" }),
            "aider" => ("Aider", Array.Empty<string>()),
            _ => (engineType, Array.Empty<string>()),
        };

        return new GenericCLIEngine(sessionId, name, binaryPath, args, onOutput, onComplete);
    }
}
