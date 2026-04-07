using System;
using System.Threading;
using System.Threading.Tasks;
using TarsyWindows.Networking;

namespace TarsyWindows.Services;

/// <summary>
/// Central orchestrator for the Windows companion — mirrors macOS DaemonManager.
/// Wires all services together: auth, relay, LAN server, screen capture, terminals, engines.
/// </summary>
public class DaemonManager
{
    private readonly SupabaseAuth _auth = new();
    private readonly MachineService _machine = new();
    private RelayClient? _relay;
    private WebSocketServer? _lanServer;
    private Timer? _heartbeatTimer;
    private Timer? _tokenRefreshTimer;
    private CancellationTokenSource? _cts;

    public async Task Start()
    {
        _cts = new CancellationTokenSource();

        // 1. Authenticate
        var token = await _auth.LoadSession();
        if (string.IsNullOrEmpty(token))
        {
            Console.WriteLine("[Daemon] No session — waiting for sign-in");
            return;
        }

        // 2. Register machine
        await _machine.Register(_auth);

        // 3. Start LAN WebSocket server
        _lanServer = new WebSocketServer(HandlePacket);
        _ = _lanServer.Start(_cts.Token);

        // 4. Connect to relay
        _relay = new RelayClient(
            token: token,
            machineSecret: _machine.Secret,
            onPacket: HandlePacket,
            tokenRefresher: _auth.RefreshToken
        );
        await _relay.Connect();

        // 5. Start heartbeat (30s)
        _heartbeatTimer = new Timer(
            _ => Task.Run(async () =>
            {
                try { await _machine.Heartbeat(_auth); }
                catch (Exception ex) { Console.WriteLine($"[Heartbeat] Error: {ex.Message}"); }
            }),
            null,
            TimeSpan.Zero,
            TimeSpan.FromSeconds(30)
        );

        // 6. Start token refresh (45 min)
        _tokenRefreshTimer = new Timer(
            _ => Task.Run(async () =>
            {
                try
                {
                    var newToken = await _auth.RefreshToken();
                    if (newToken != null) _relay?.UpdateToken(newToken);
                }
                catch (Exception ex) { Console.WriteLine($"[TokenRefresh] Error: {ex.Message}"); }
            }),
            null,
            TimeSpan.FromMinutes(45),
            TimeSpan.FromMinutes(45)
        );

        // 7. Prevent sleep
        SleepPrevention.Prevent();

        Console.WriteLine("[Daemon] Started successfully");
    }

    public async Task Stop()
    {
        _heartbeatTimer?.Dispose();
        _tokenRefreshTimer?.Dispose();
        _relay?.Disconnect();
        _lanServer?.Stop();
        _cts?.Cancel();

        await _machine.SetOffline(_auth);
        SleepPrevention.Release();

        Console.WriteLine("[Daemon] Stopped");
    }

    public void ShowOnboarding()
    {
        // TODO: Open onboarding window (WebView2 for OAuth)
        Console.WriteLine("[Daemon] Onboarding requested");
    }

    private async Task HandlePacket(WSPacket packet, string clientId)
    {
        Console.WriteLine($"[Daemon] Received {packet.Action} from {clientId}");

        // Packet dispatch — mirrors DaemonManager.swift handlePacket
        switch (packet.Action)
        {
            case WSAction.Ping:
                await SendToClient(WSPacket.Create(WSAction.Pong), clientId);
                break;

            case WSAction.Pong:
                break;

            // TODO: Add all action handlers as they are implemented
            // - stream:start/stop
            // - remote:tap/scroll/keyboard
            // - terminal:create/input/close
            // - engine:create/message/close
            // - git:diff/checkpoint/rollback/history/branches
            // - file:tree/read
            // - workspace:scan_repos/create
            // - devtools:process_list/ports_list/system_resources
            // - mcp:list/health_check
            // - sudo:request/response

            default:
                await SendToClient(
                    WSPacket.Create(WSAction.Error, new Dictionary<string, string>
                    {
                        ["message"] = $"Unhandled action: {packet.Action}"
                    }),
                    clientId
                );
                break;
        }
    }

    private async Task SendToClient(WSPacket packet, string clientId)
    {
        if (clientId == "relay" && _relay != null)
        {
            await _relay.Send(packet);
        }
        else if (_lanServer != null)
        {
            await _lanServer.Send(packet, clientId);
        }
    }
}
