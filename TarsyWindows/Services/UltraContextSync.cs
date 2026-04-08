using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Services;

/// <summary>
/// UltraContext output buffering and session file watcher.
/// Mirrors macOS UltraContextDaemon.
/// </summary>
public class UltraContextSync : IDisposable
{
    private const int MaxBufferSize = 16_384;    // 16KB
    private const int FlushIntervalMs = 3_000;   // 3s inactivity
    private const int MaxMessageLength = 8_000;  // truncation limit
    private const int MaxCompletionLength = 4_000;

    private readonly HttpClient _http = new();
    private readonly ConcurrentDictionary<string, SessionBuffer> _buffers = new();
    private FileSystemWatcher? _watcher;
    private string? _authToken;
    private string? _supabaseUrl;
    private CancellationTokenSource? _cts;

    // Callbacks
    private readonly Action<string, string> _onStatusUpdate; // (key, value)

    private class SessionBuffer
    {
        public string SessionId { get; set; } = "";
        public string? ContextId { get; set; }
        public string? EngineName { get; set; }
        public string? WorkspacePath { get; set; }
        public StringBuilder Buffer { get; } = new();
        public DateTime LastActivity { get; set; } = DateTime.UtcNow;
        public System.Threading.Timer? FlushTimer { get; set; }
    }

    public UltraContextSync(Action<string, string> onStatusUpdate)
    {
        _onStatusUpdate = onStatusUpdate;
    }

    /// <summary>
    /// Initialize with auth token and start file watcher.
    /// </summary>
    public void Start(string authToken, string supabaseUrl)
    {
        _authToken = authToken;
        _supabaseUrl = supabaseUrl;
        _cts = new CancellationTokenSource();

        // Start watching for session files
        StartFileWatcher();

        Console.WriteLine("[UltraContext] Started");
    }

    /// <summary>
    /// Register a new engine session for context tracking.
    /// </summary>
    public void RegisterSession(string sessionId, string engineName, string workspacePath)
    {
        var buffer = new SessionBuffer
        {
            SessionId = sessionId,
            EngineName = engineName,
            WorkspacePath = workspacePath,
        };

        _buffers[sessionId] = buffer;
        Console.WriteLine($"[UltraContext] Registered session {sessionId} ({engineName})");
    }

    /// <summary>
    /// Buffer agent output — flushes after 3s inactivity or 16KB.
    /// </summary>
    public void AgentOutput(string sessionId, string text)
    {
        if (!_buffers.TryGetValue(sessionId, out var buffer)) return;

        buffer.Buffer.Append(text);
        buffer.LastActivity = DateTime.UtcNow;

        // Size-based flush
        if (buffer.Buffer.Length >= MaxBufferSize)
        {
            _ = FlushBuffer(sessionId);
            return;
        }

        // Reset inactivity timer
        buffer.FlushTimer?.Dispose();
        buffer.FlushTimer = new System.Threading.Timer(
            _ => _ = FlushBuffer(sessionId),
            null,
            FlushIntervalMs,
            Timeout.Infinite
        );
    }

    /// <summary>
    /// User message — flush buffered output first to preserve order.
    /// </summary>
    public async Task UserMessage(string sessionId, string message)
    {
        // Flush any buffered output first
        await FlushBuffer(sessionId);

        if (!_buffers.TryGetValue(sessionId, out var buffer)) return;

        await AppendToContext(buffer, "user", Truncate(message, MaxMessageLength));
    }

    /// <summary>
    /// Engine completed — flush and send completion summary.
    /// </summary>
    public async Task EngineCompleted(string sessionId, string? summary = null)
    {
        await FlushBuffer(sessionId);

        if (_buffers.TryRemove(sessionId, out var buffer))
        {
            var completionMsg = summary != null
                ? Truncate($"[completed] {summary}", MaxCompletionLength)
                : "[completed]";

            await AppendToContext(buffer, "system", completionMsg);

            buffer.FlushTimer?.Dispose();
            Console.WriteLine($"[UltraContext] Session {sessionId} completed");
        }
    }

    /// <summary>
    /// Get current UltraContext status.
    /// </summary>
    public string GetStatus()
    {
        return JsonSerializer.Serialize(new
        {
            activeSessions = _buffers.Count,
            watcherRunning = _watcher != null,
            sessions = _buffers.Keys.ToArray(),
        });
    }

    // ── Internal ──

    private async Task FlushBuffer(string sessionId)
    {
        if (!_buffers.TryGetValue(sessionId, out var buffer)) return;
        if (buffer.Buffer.Length == 0) return;

        var text = buffer.Buffer.ToString();
        buffer.Buffer.Clear();
        buffer.FlushTimer?.Dispose();
        buffer.FlushTimer = null;

        await AppendToContext(buffer, "assistant", Truncate(text, MaxMessageLength));
    }

    private async Task AppendToContext(SessionBuffer buffer, string role, string content)
    {
        if (_supabaseUrl == null || _authToken == null) return;

        try
        {
            // Ensure context exists (lazy creation)
            if (buffer.ContextId == null)
            {
                buffer.ContextId = await CreateContext(buffer);
                if (buffer.ContextId == null) return;
            }

            var payload = JsonSerializer.Serialize(new
            {
                context_id = buffer.ContextId,
                role,
                content,
            });

            using var request = new HttpRequestMessage(HttpMethod.Post,
                $"{_supabaseUrl}/functions/v1/ultracontext-proxy");
            request.Headers.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _authToken);
            request.Content = new StringContent(payload, Encoding.UTF8, "application/json");

            var response = await _http.SendAsync(request);

            if (!response.IsSuccessStatusCode)
            {
                Console.WriteLine($"[UltraContext] Append failed: {response.StatusCode}");
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[UltraContext] Append error: {ex.Message}");
        }
    }

    private async Task<string?> CreateContext(SessionBuffer buffer)
    {
        if (_supabaseUrl == null || _authToken == null) return null;

        try
        {
            var payload = JsonSerializer.Serialize(new
            {
                engine = buffer.EngineName,
                workspace = buffer.WorkspacePath,
                session_id = buffer.SessionId,
            });

            using var request = new HttpRequestMessage(HttpMethod.Post,
                $"{_supabaseUrl}/functions/v1/ultracontext-proxy/create");
            request.Headers.Authorization =
                new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _authToken);
            request.Content = new StringContent(payload, Encoding.UTF8, "application/json");

            var response = await _http.SendAsync(request);

            if (response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("id", out var idProp))
                    return idProp.GetString();
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[UltraContext] CreateContext error: {ex.Message}");
        }

        return null;
    }

    // ── File Watcher (W16.2) ──

    private void StartFileWatcher()
    {
        var watchPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude", "projects"
        );

        if (!Directory.Exists(watchPath))
        {
            Console.WriteLine($"[UltraContext] Watch path does not exist: {watchPath}");
            return;
        }

        try
        {
            _watcher = new FileSystemWatcher(watchPath)
            {
                Filter = "*.jsonl",
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.CreationTime,
                EnableRaisingEvents = true,
            };

            _watcher.Changed += OnSessionFileChanged;
            _watcher.Created += OnSessionFileChanged;

            Console.WriteLine($"[UltraContext] Watching {watchPath} for session files");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[UltraContext] FileWatcher error: {ex.Message}");
        }
    }

    private void OnSessionFileChanged(object sender, FileSystemEventArgs e)
    {
        _onStatusUpdate("ultracontext_session_file", e.FullPath);
    }

    private static string Truncate(string text, int maxLength)
    {
        if (text.Length <= maxLength) return text;
        return text[..maxLength] + " [truncated]";
    }

    public void Dispose()
    {
        _cts?.Cancel();

        foreach (var (_, buffer) in _buffers)
            buffer.FlushTimer?.Dispose();
        _buffers.Clear();

        _watcher?.Dispose();
        _http.Dispose();
        _cts?.Dispose();
    }
}
