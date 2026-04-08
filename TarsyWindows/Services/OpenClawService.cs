using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Services;

/// <summary>
/// OpenClaw local LLM gateway client — mirrors macOS OpenClawService.
/// Communicates with the OpenClaw gateway on port 18789.
/// </summary>
public class OpenClawService : IDisposable
{
    private const int GatewayPort = 18789;
    private const string BaseUrl = "http://localhost:18789";
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(5) };
    private Process? _gatewayProcess;

    // Callbacks
    private readonly Action<string> _onOutput;       // streaming text chunk
    private readonly Action _onComplete;              // generation complete
    private readonly Action<string> _onError;         // error message

    public bool IsAvailable { get; private set; }

    public OpenClawService(Action<string> onOutput, Action onComplete, Action<string> onError)
    {
        _onOutput = onOutput;
        _onComplete = onComplete;
        _onError = onError;
    }

    /// <summary>
    /// Check if OpenClaw binary is installed and gateway is reachable.
    /// </summary>
    public async Task<bool> CheckHealth()
    {
        // First check if gateway is already running
        try
        {
            var response = await _http.GetAsync($"{BaseUrl}/health");
            if (response.IsSuccessStatusCode)
            {
                IsAvailable = true;
                return true;
            }
        }
        catch { }

        // Check if binary exists
        var binaryPath = FindOpenClawBinary();
        IsAvailable = binaryPath != null;
        return IsAvailable;
    }

    /// <summary>
    /// Start the OpenClaw gateway process if not already running.
    /// </summary>
    public async Task<bool> StartGateway()
    {
        // Check if already running
        try
        {
            var response = await _http.GetAsync($"{BaseUrl}/health");
            if (response.IsSuccessStatusCode) return true;
        }
        catch { }

        var binaryPath = FindOpenClawBinary();
        if (binaryPath == null)
        {
            _onError("OpenClaw binary not found");
            return false;
        }

        try
        {
            _gatewayProcess = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = binaryPath,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                },
            };
            _gatewayProcess.StartInfo.ArgumentList.Add("gateway");
            _gatewayProcess.StartInfo.ArgumentList.Add("--port");
            _gatewayProcess.StartInfo.ArgumentList.Add(GatewayPort.ToString());

            _gatewayProcess.Start();

            // Wait for gateway to be ready
            for (int i = 0; i < 20; i++)
            {
                await Task.Delay(500);
                try
                {
                    var response = await _http.GetAsync($"{BaseUrl}/health");
                    if (response.IsSuccessStatusCode)
                    {
                        IsAvailable = true;
                        Console.WriteLine("[OpenClaw] Gateway started on port 18789");
                        return true;
                    }
                }
                catch { }
            }

            _onError("OpenClaw gateway failed to start within 10s");
            return false;
        }
        catch (Exception ex)
        {
            _onError($"Failed to start OpenClaw: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Send a message and stream the response via SSE.
    /// </summary>
    public async Task SendMessage(string message, string? model = null)
    {
        try
        {
            var payload = new Dictionary<string, object>
            {
                ["message"] = message,
                ["stream"] = true,
            };
            if (model != null) payload["model"] = model;

            var json = JsonSerializer.Serialize(payload);
            var content = new StringContent(json, Encoding.UTF8, "application/json");

            using var request = new HttpRequestMessage(HttpMethod.Post, $"{BaseUrl}/v1/chat");
            request.Content = content;

            using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            if (!response.IsSuccessStatusCode)
            {
                _onError($"OpenClaw error: {response.StatusCode}");
                return;
            }

            // Parse SSE stream
            using var stream = await response.Content.ReadAsStreamAsync();
            using var reader = new StreamReader(stream, Encoding.UTF8);

            while (!reader.EndOfStream)
            {
                var line = await reader.ReadLineAsync();
                if (line == null) break;

                if (line.StartsWith("data: "))
                {
                    var data = line[6..];
                    if (data == "[DONE]")
                    {
                        _onComplete();
                        break;
                    }

                    try
                    {
                        using var doc = JsonDocument.Parse(data);
                        var root = doc.RootElement;

                        // Extract text content from SSE event
                        if (root.TryGetProperty("choices", out var choices) &&
                            choices.GetArrayLength() > 0)
                        {
                            var delta = choices[0].GetProperty("delta");
                            if (delta.TryGetProperty("content", out var contentProp))
                            {
                                var text = contentProp.GetString();
                                if (!string.IsNullOrEmpty(text))
                                    _onOutput(text);
                            }
                        }
                        else if (root.TryGetProperty("text", out var textProp))
                        {
                            var text = textProp.GetString();
                            if (!string.IsNullOrEmpty(text))
                                _onOutput(text);
                        }
                    }
                    catch { }
                }
            }
        }
        catch (Exception ex)
        {
            _onError($"OpenClaw stream error: {ex.Message}");
        }
    }

    /// <summary>
    /// Get OpenClaw status information.
    /// </summary>
    public async Task<Dictionary<string, string>> GetStatus()
    {
        var status = new Dictionary<string, string>
        {
            ["available"] = IsAvailable.ToString(),
            ["port"] = GatewayPort.ToString(),
        };

        try
        {
            var response = await _http.GetAsync($"{BaseUrl}/health");
            status["running"] = response.IsSuccessStatusCode.ToString();
            if (response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync();
                status["health"] = body;
            }
        }
        catch
        {
            status["running"] = "False";
        }

        return status;
    }

    private static string? FindOpenClawBinary()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

        string[] searchPaths =
        {
            Path.Combine(home, ".openclaw", "bin", "openclaw.exe"),
            Path.Combine(home, ".local", "bin", "openclaw.exe"),
            Path.Combine(localAppData, "Programs", "openclaw", "openclaw.exe"),
            Path.Combine(appData, "npm", "openclaw.cmd"),
            Path.Combine(home, ".bun", "bin", "openclaw.exe"),
        };

        foreach (var p in searchPaths)
        {
            if (File.Exists(p)) return p;
        }

        // Try PATH via where.exe
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "where.exe",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                },
            };
            process.StartInfo.ArgumentList.Add("openclaw.exe");
            process.Start();
            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(3000);

            var firstLine = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();
            if (firstLine != null && File.Exists(firstLine)) return firstLine;
        }
        catch { }

        return null;
    }

    public void Dispose()
    {
        try
        {
            if (_gatewayProcess is { HasExited: false })
            {
                _gatewayProcess.Kill(entireProcessTree: true);
            }
            _gatewayProcess?.Dispose();
        }
        catch { }

        _http.Dispose();
    }
}
