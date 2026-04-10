using System;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using TarsyWindows.Security;

namespace TarsyWindows.Networking;

/// <summary>
/// Relay WebSocket client — connects to wss://tarsy-relay.fly.dev/ws.
/// Stub — full implementation in W5 task.
/// </summary>
public class RelayClient
{
    private ClientWebSocket? _ws;
    private string _token;
    private readonly MachineKeyStore _keyStore;
    private readonly string _machineId;
    private readonly string _userId;
    private readonly Func<WSPacket, string, Task> _onPacket;
    private readonly Func<Task<string?>> _tokenRefresher;
    private CancellationTokenSource? _cts;
    private int _reconnectAttempts;
    private bool _intentionalDisconnect;

    // E2E encryption
    private E2ECrypto _e2e = new();
    public E2ECrypto E2E => _e2e;

    public bool IsConnected => _ws?.State == WebSocketState.Open;

    public RelayClient(
        string token,
        MachineKeyStore keyStore,
        string machineId,
        string userId,
        Func<WSPacket, string, Task> onPacket,
        Func<Task<string?>> tokenRefresher)
    {
        _token = token;
        _keyStore = keyStore;
        _machineId = machineId;
        _userId = userId;
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

        // Encrypt if E2E is ready and not a system packet
        if (_e2e.IsReady && !IsSystemAction(packet.Action))
        {
            var encrypted = _e2e.EncryptPacket(packet);
            if (encrypted != null)
            {
                var encJson = encrypted.Encode();
                var encBytes = Encoding.UTF8.GetBytes(encJson);
                await _ws.SendAsync(encBytes, WebSocketMessageType.Text, true, CancellationToken.None);
                return;
            }
        }

        var json = packet.Encode();
        var bytes = Encoding.UTF8.GetBytes(json);
        await _ws.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
    }

    public async Task SendBinary(byte[] data)
    {
        if (_ws?.State != WebSocketState.Open) return;

        // Encrypt binary if E2E is ready
        if (_e2e.IsReady)
        {
            var encrypted = _e2e.EncryptBinary(data);
            if (encrypted != null)
            {
                await _ws.SendAsync(encrypted, WebSocketMessageType.Binary, true, CancellationToken.None);
                return;
            }
        }

        await _ws.SendAsync(data, WebSocketMessageType.Binary, true, CancellationToken.None);
    }

    /// <summary>
    /// System actions that must NOT be encrypted (auth, ping/pong, e2e key exchange).
    /// </summary>
    private static bool IsSystemAction(string action)
    {
        return action is WSAction.Auth or WSAction.AuthSuccess or WSAction.AuthFail
            or WSAction.Ping or WSAction.Pong
            or WSAction.E2eKeyExchange or WSAction.E2eKeyExchangeResponse or WSAction.E2eEncrypted;
    }

    private async Task OpenWebSocket()
    {
        _ws?.Dispose();
        _ws = new ClientWebSocket();
        _ws.Options.SetBuffer(4 * 1024 * 1024, 4 * 1024 * 1024); // 4 MB

        try
        {
            await _ws.ConnectAsync(new Uri(Models.TarsyConfig.RelayUrl), _cts!.Token);

            // Reset E2E for new connection (E2E key exchange happens via a
            // separate `e2e:key_exchange` packet later — not in the auth message).
            _e2e.Reset();

            // Phase 3 machine auth: sign a canonical string
            //   "<machine_id>:<timestamp_ms>:<user_id>"
            // with the P-256 private key in the TPM/software store. The relay
            // fetches our public key from machine_tokens.public_key and
            // verifies the signature. No shared secret is transmitted.
            var timestampMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var canonical = $"{_machineId}:{timestampMs}:{_userId}";
            var canonicalBytes = Encoding.UTF8.GetBytes(canonical);
            var signatureDer = _keyStore.Sign(canonicalBytes);

            var authPayload = new System.Collections.Generic.Dictionary<string, string>
            {
                ["token"] = _token,
                ["role"] = "machine",
                ["machine_id"] = _machineId,
                ["timestamp"] = timestampMs.ToString(),
                ["signature"] = Convert.ToBase64String(signatureDer),
                ["machinePublicKey"] = Convert.ToBase64String(_keyStore.PublicKeyDer),
            };
            var authPacket = WSPacket.Create(WSAction.Auth, authPayload);
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

                        // Handle E2E key exchange
                        if (packet.Action == WSAction.E2eKeyExchangeResponse)
                        {
                            var remoteKey = packet.Payload?.GetValueOrDefault("publicKey", "");
                            if (!string.IsNullOrEmpty(remoteKey))
                            {
                                var ok = _e2e.CompleteKeyExchange(remoteKey);
                                Console.WriteLine($"[Relay] E2E key exchange: {(ok ? "success" : "failed")}");
                            }
                            continue;
                        }

                        // Decrypt E2E encrypted packets
                        if (packet.Action == WSAction.E2eEncrypted && _e2e.IsReady)
                        {
                            var inner = _e2e.DecryptPacket(packet);
                            if (inner != null)
                            {
                                await _onPacket(inner, "relay");
                                continue;
                            }
                        }

                        await _onPacket(packet, "relay");
                    }
                    catch { /* malformed packet */ }
                }
                else if (result.MessageType == WebSocketMessageType.Binary)
                {
                    // Decrypt binary if E2E is ready
                    if (_e2e.IsReady)
                    {
                        var data = new byte[result.Count];
                        Buffer.BlockCopy(buffer, 0, data, 0, result.Count);
                        var decrypted = _e2e.DecryptBinary(data);
                        if (decrypted != null)
                        {
                            // Pass decrypted binary frame upstream
                            // (binary frames are sent from client→machine for input,
                            //  not typically received on the machine side)
                        }
                    }
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
