using System;
using System.Collections.Concurrent;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using TarsyWindows.Models;

namespace TarsyWindows.Networking;

/// <summary>
/// LAN WebSocket server on port 8642 — mirrors WebSocketServer.swift.
/// Stub — full implementation in W6 task.
/// </summary>
public class WebSocketServer
{
    private HttpListener? _listener;
    private readonly Func<WSPacket, string, Task> _onPacket;
    private readonly ConcurrentDictionary<string, WebSocket> _clients = new();

    public WebSocketServer(Func<WSPacket, string, Task> onPacket)
    {
        _onPacket = onPacket;
    }

    public async Task Start(CancellationToken ct)
    {
        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://+:{TarsyConfig.WebSocketPort}/");

        try
        {
            _listener.Start();
            Console.WriteLine($"[LAN] Server listening on port {TarsyConfig.WebSocketPort}");

            while (!ct.IsCancellationRequested)
            {
                var context = await _listener.GetContextAsync();
                if (context.Request.IsWebSocketRequest)
                {
                    _ = HandleClient(context, ct);
                }
                else
                {
                    context.Response.StatusCode = 400;
                    context.Response.Close();
                }
            }
        }
        catch (OperationCanceledException) { /* shutdown */ }
        catch (Exception ex)
        {
            Console.WriteLine($"[LAN] Server error: {ex.Message}");
        }
    }

    public void Stop()
    {
        _listener?.Stop();
        foreach (var (id, ws) in _clients)
        {
            try { ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "Server shutdown", CancellationToken.None).Wait(1000); }
            catch { /* cleanup */ }
        }
        _clients.Clear();
    }

    public async Task Send(WSPacket packet, string clientId)
    {
        if (_clients.TryGetValue(clientId, out var ws) && ws.State == WebSocketState.Open)
        {
            var json = packet.Encode();
            var bytes = Encoding.UTF8.GetBytes(json);
            await ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
        }
    }

    private async Task HandleClient(HttpListenerContext context, CancellationToken ct)
    {
        var wsContext = await context.AcceptWebSocketAsync(null);
        var ws = wsContext.WebSocket;
        var clientId = Guid.NewGuid().ToString();

        _clients.TryAdd(clientId, ws);
        Console.WriteLine($"[LAN] Client connected: {clientId}");

        var buffer = new byte[1_048_576]; // 1 MB

        try
        {
            // TODO: Auth timeout (3s), rate limiting, local network validation

            while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
            {
                var result = await ws.ReceiveAsync(buffer, ct);

                if (result.MessageType == WebSocketMessageType.Close)
                    break;

                if (result.MessageType == WebSocketMessageType.Text)
                {
                    var json = Encoding.UTF8.GetString(buffer, 0, result.Count);
                    try
                    {
                        var packet = WSPacket.Decode(json);
                        await _onPacket(packet, clientId);
                    }
                    catch { /* malformed */ }
                }
            }
        }
        catch (OperationCanceledException) { /* shutdown */ }
        catch (Exception ex)
        {
            Console.WriteLine($"[LAN] Client error: {ex.Message}");
        }
        finally
        {
            _clients.TryRemove(clientId, out _);
            Console.WriteLine($"[LAN] Client disconnected: {clientId}");
        }
    }
}
