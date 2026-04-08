using System;
using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using TarsyWindows.Models;

namespace TarsyWindows.Networking;

/// <summary>
/// Temporary localhost HTTP server for OAuth callback.
/// Opens the browser → Supabase OAuth → redirects back to localhost → captures tokens.
/// </summary>
public class OAuthServer : IDisposable
{
    private HttpListener? _listener;
    private readonly int _port;
    private readonly TaskCompletionSource<OAuthResult> _tcs = new();

    public OAuthServer()
    {
        // Find an available port
        using var sock = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        sock.Start();
        _port = ((IPEndPoint)sock.LocalEndpoint).Port;
        sock.Stop();
    }

    /// <summary>
    /// Start the GitHub OAuth flow. Opens the browser and waits for callback.
    /// Returns tokens on success, throws on timeout/cancel.
    /// </summary>
    public async Task<OAuthResult> StartGitHubOAuth(CancellationToken ct = default)
    {
        var redirectUrl = $"http://localhost:{_port}/callback";
        var oauthUrl = $"{TarsyConfig.SupabaseUrl}/auth/v1/authorize?provider=github&redirect_to={Uri.EscapeDataString(redirectUrl)}";

        // Start listener
        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://localhost:{_port}/");
        _listener.Start();

        // Open browser
        Process.Start(new ProcessStartInfo(oauthUrl) { UseShellExecute = true });

        // Wait for callback (2 minute timeout)
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, timeout.Token);

        _ = ListenForCallback(linked.Token);

        try
        {
            return await _tcs.Task.WaitAsync(linked.Token);
        }
        catch (OperationCanceledException)
        {
            throw new Exception("OAuth timed out or was cancelled");
        }
    }

    private async Task ListenForCallback(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested && _listener?.IsListening == true)
            {
                var contextTask = _listener.GetContextAsync();
                var completed = await Task.WhenAny(contextTask, Task.Delay(-1, ct));
                if (completed != contextTask) break;

                var context = await contextTask;
                var path = context.Request.Url?.AbsolutePath ?? "";

                if (path == "/callback")
                {
                    // Supabase puts tokens in the URL fragment (#access_token=...).
                    // Fragments are NOT sent to the server, so we serve a page
                    // that reads the fragment and posts it back to /token.
                    var html = GetCallbackHtml();
                    var bytes = Encoding.UTF8.GetBytes(html);
                    context.Response.ContentType = "text/html; charset=utf-8";
                    context.Response.ContentLength64 = bytes.Length;
                    await context.Response.OutputStream.WriteAsync(bytes, ct);
                    context.Response.Close();
                }
                else if (path == "/token")
                {
                    // Read the posted tokens
                    using var reader = new System.IO.StreamReader(context.Request.InputStream);
                    var body = await reader.ReadToEndAsync(ct);

                    // Respond with success page
                    var successHtml = GetSuccessHtml();
                    var bytes = Encoding.UTF8.GetBytes(successHtml);
                    context.Response.ContentType = "text/html; charset=utf-8";
                    context.Response.ContentLength64 = bytes.Length;
                    await context.Response.OutputStream.WriteAsync(bytes, ct);
                    context.Response.Close();

                    // Parse tokens
                    try
                    {
                        using var doc = JsonDocument.Parse(body);
                        var result = new OAuthResult
                        {
                            AccessToken = doc.RootElement.GetProperty("access_token").GetString() ?? "",
                            RefreshToken = doc.RootElement.GetProperty("refresh_token").GetString() ?? "",
                        };
                        _tcs.TrySetResult(result);
                    }
                    catch (Exception ex)
                    {
                        _tcs.TrySetException(new Exception($"Failed to parse OAuth tokens: {ex.Message}"));
                    }
                    break;
                }
                else
                {
                    context.Response.StatusCode = 404;
                    context.Response.Close();
                }
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _tcs.TrySetException(ex);
        }
    }

    private static string GetCallbackHtml() => """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body {
                    background: #131316;
                    color: #e4e4e7;
                    font-family: 'Cascadia Code', 'Consolas', monospace;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    margin: 0;
                }
                .container {
                    text-align: center;
                }
                .spinner {
                    width: 24px; height: 24px;
                    border: 2px solid #2a2a30;
                    border-top-color: #e4e4e7;
                    border-radius: 50%;
                    animation: spin 0.8s linear infinite;
                    margin: 0 auto 16px;
                }
                @keyframes spin { to { transform: rotate(360deg); } }
                p { color: #71717a; font-size: 13px; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="spinner"></div>
                <p>authenticating...</p>
            </div>
            <script>
                const hash = window.location.hash.substring(1);
                const params = new URLSearchParams(hash);
                const data = {
                    access_token: params.get('access_token') || '',
                    refresh_token: params.get('refresh_token') || '',
                };
                fetch('/token', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(data),
                }).then(() => {
                    // Page will be replaced by success response
                }).catch(() => {
                    document.querySelector('p').textContent = 'error — close this tab and try again';
                });
            </script>
        </body>
        </html>
        """;

    private static string GetSuccessHtml() => """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body {
                    background: #131316;
                    color: #e4e4e7;
                    font-family: 'Cascadia Code', 'Consolas', monospace;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    margin: 0;
                }
                .container { text-align: center; }
                h2 { font-size: 18px; margin-bottom: 8px; }
                p { color: #71717a; font-size: 13px; }
            </style>
        </head>
        <body>
            <div class="container">
                <h2>authenticated</h2>
                <p>you can close this tab and return to tarsy</p>
            </div>
            <script>setTimeout(() => window.close(), 2000);</script>
        </body>
        </html>
        """;

    public void Dispose()
    {
        try { _listener?.Stop(); _listener?.Close(); } catch { }
    }
}

public class OAuthResult
{
    public string AccessToken { get; set; } = "";
    public string RefreshToken { get; set; } = "";
}
