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
    private readonly ConcurrentDictionary<string, E2ECrypto> _clientE2E = new();

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

        foreach (var (_, e2e) in _clientE2E)
            e2e.Dispose();
        _clientE2E.Clear();
    }

    public async Task Send(WSPacket packet, string clientId)
    {
        if (_clients.TryGetValue(clientId, out var ws) && ws.State == WebSocketState.Open)
        {
            // Encrypt if E2E is ready for this client
            if (_clientE2E.TryGetValue(clientId, out var e2e) && e2e.IsReady
                && packet.Action is not (WSAction.Auth or WSAction.AuthSuccess or WSAction.AuthFail
                    or WSAction.Ping or WSAction.Pong
                    or WSAction.E2eKeyExchange or WSAction.E2eKeyExchangeResponse or WSAction.E2eEncrypted))
            {
                var encrypted = e2e.EncryptPacket(packet);
                if (encrypted != null)
                {
                    var encJson = encrypted.Encode();
                    var encBytes = Encoding.UTF8.GetBytes(encJson);
                    await ws.SendAsync(encBytes, WebSocketMessageType.Text, true, CancellationToken.None);
                    return;
                }
            }

            var json = packet.Encode();
            var bytes = Encoding.UTF8.GetBytes(json);
            await ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
        }
    }

    public async Task SendBinary(byte[] data, string clientId)
    {
        if (_clients.TryGetValue(clientId, out var ws) && ws.State == WebSocketState.Open)
        {
            // Encrypt binary if E2E is ready
            if (_clientE2E.TryGetValue(clientId, out var e2e) && e2e.IsReady)
            {
                var encrypted = e2e.EncryptBinary(data);
                if (encrypted != null)
                {
                    await ws.SendAsync(encrypted, WebSocketMessageType.Binary, true, CancellationToken.None);
                    return;
                }
            }

            await ws.SendAsync(data, WebSocketMessageType.Binary, true, CancellationToken.None);
        }
    }

    private async Task HandleClient(HttpListenerContext context, CancellationToken ct)
    {
        var wsContext = await context.AcceptWebSocketAsync(null);
        var ws = wsContext.WebSocket;
        var clientId = Guid.NewGuid().ToString();

        _clients.TryAdd(clientId, ws);
        var e2e = new E2ECrypto();
        _clientE2E.TryAdd(clientId, e2e);
        Console.WriteLine($"[LAN] Client connected: {clientId}");

        var buffer = new byte[1_048_576]; // 1 MB

        try
        {
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

                        // Handle E2E key exchange from client
                        if (packet.Action == WSAction.E2eKeyExchange)
                        {
                            var remoteKey = packet.Payload?.GetValueOrDefault("publicKey", "");
                            if (!string.IsNullOrEmpty(remoteKey))
                            {
                                var ok = e2e.CompleteKeyExchange(remoteKey);
                                Console.WriteLine($"[LAN] E2E key exchange with {clientId}: {(ok ? "success" : "failed")}");

                                // Send our public key back
                                var response = WSPacket.Create(WSAction.E2eKeyExchangeResponse, new()
                                {
                                    ["publicKey"] = e2e.PublicKeyBase64,
                                });
                                var respJson = response.Encode();
                                var respBytes = Encoding.UTF8.GetBytes(respJson);
                                await ws.SendAsync(respBytes, WebSocketMessageType.Text, true, CancellationToken.None);
                            }
                            continue;
                        }

                        // Decrypt E2E encrypted packets
                        if (packet.Action == WSAction.E2eEncrypted && e2e.IsReady)
                        {
                            var inner = e2e.DecryptPacket(packet);
                            if (inner != null)
                            {
                                await _onPacket(inner, clientId);
                                continue;
                            }
                        }

                        await _onPacket(packet, clientId);
                    }
                    catch { /* malformed */ }
                }
                else if (result.MessageType == WebSocketMessageType.Binary && e2e.IsReady)
                {
                    var data = new byte[result.Count];
                    Buffer.BlockCopy(buffer, 0, data, 0, result.Count);
                    var decrypted = e2e.DecryptBinary(data);
                    // Binary frames from client (if any) would be handled here
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
            if (_clientE2E.TryRemove(clientId, out var removedE2E))
                removedE2E.Dispose();
            Console.WriteLine($"[LAN] Client disconnected: {clientId}");
        }
    }
}
