using System;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Networking;

/// <summary>
/// Relay WebSocket client — connects to wss://tarsy-relay.fly.dev/ws.
/// Stub — full implementation in W5 task.
/// </summary>
public class RelayClient
{
    private ClientWebSocket? _ws;
    private string _token;
    private readonly string? _machineSecret;
    private readonly Func<WSPacket, string, Task> _onPacket;
    private readonly Func<Task<string?>> _tokenRefresher;
    private CancellationTokenSource? _cts;
    private int _reconnectAttempts;
    private bool _intentionalDisconnect;

    public bool IsConnected => _ws?.State == WebSocketState.Open;

    public RelayClient(
        string token,
        string? machineSecret,
        Func<WSPacket, string, Task> onPacket,
        Func<Task<string?>> tokenRefresher)
    {
        _token = token;
        _machineSecret = machineSecret;
        _onPacket = onPacket;
        _tokenRefresher = tokenRefresher;
    }

    public async Task Connect()
    {
        _intentionalDisconnect = false;
        _cts = new CancellationTokenSource();
        await OpenWebSocket();
    }

    public void Disconnect()
    {
        _intentionalDisconnect = true;
        _cts?.Cancel();
        _ws?.Dispose();
        _ws = null;
    }

    public void UpdateToken(string token)
    {
        _token = token;
    }

    public async Task Send(WSPacket packet)
    {
        if (_ws?.State != WebSocketState.Open) return;

        var json = packet.Encode();
        var bytes = Encoding.UTF8.GetBytes(json);
        await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
    }

    private async Task OpenWebSocket()
    {
        _ws?.Dispose();
        _ws = new ClientWebSocket();
        _ws.Options.SetBuffer(4 * 1024 * 1024, 4 * 1024 * 1024); // 4 MB

        try
        {
            await _ws.ConnectAsync(new Uri(Models.TarsyConfig.RelayUrl), _cts!.Token);

            // Send auth
            var authPacket = WSPacket.Create(WSAction.Auth, new()
            {
                ["token"] = _token,
                ["role"] = "machine",
                ["machineSecret"] = _machineSecret ?? "",
            });
            await Send(authPacket);

            _reconnectAttempts = 0;

            // Start receive loop
            _ = ReceiveLoop();
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Relay] Connect failed: {ex.Message}");
            await ScheduleReconnect();
        }
    }

    private async Task ReceiveLoop()
    {
        var buffer = new byte[4 * 1024 * 1024]; // 4 MB

        try
        {
            while (_ws?.State == WebSocketState.Open && !(_cts?.IsCancellationRequested ?? true))
            {
                var result = await _ws.ReceiveAsync(buffer, _cts!.Token);

                if (result.MessageType == WebSocketMessageType.Close)
                {
                    break;
                }

                if (result.MessageType == WebSocketMessageType.Text)
                {
                    var json = Encoding.UTF8.GetString(buffer, 0, result.Count);
                    try
                    {
                        var packet = WSPacket.Decode(json);
                        await _onPacket(packet, "relay");
                    }
                    catch { /* malformed packet */ }
                }
                else if (result.MessageType == WebSocketMessageType.Binary)
                {
                    // TODO: Handle binary frames (H.264, screenshots)
                }
            }
        }
        catch (OperationCanceledException) { /* intentional */ }
        catch (Exception ex)
        {
            Console.WriteLine($"[Relay] Receive error: {ex.Message}");
        }

        if (!_intentionalDisconnect)
        {
            await ScheduleReconnect();
        }
    }

    private async Task ScheduleReconnect()
    {
        _reconnectAttempts++;
        var baseDelay = Math.Min(Math.Pow(2, _reconnectAttempts), 60);
        var jitter = Random.Shared.NextDouble() * Math.Min(baseDelay * 0.3, 10);
        var delay = (int)((baseDelay + jitter) * 1000);

        Console.WriteLine($"[Relay] Reconnecting in {delay}ms (attempt {_reconnectAttempts})");
        await Task.Delay(delay);

        // Refresh token
        var newToken = await _tokenRefresher();
        if (newToken != null) _token = newToken;

        await OpenWebSocket();
    }
}
