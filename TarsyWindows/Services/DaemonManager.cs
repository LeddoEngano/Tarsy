using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using TarsyWindows.Networking;
using TarsyWindows.Stream;
using TarsyWindows.Terminal;

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
    private System.Threading.Timer? _heartbeatTimer;
    private System.Threading.Timer? _tokenRefreshTimer;
    private CancellationTokenSource? _cts;

    // ── Services ──
    private TerminalSessionManager? _terminals;
    private ScreenCaptureService? _screenCapture;
    private readonly ConcurrentDictionary<string, IAIEngine> _engineSessions = new();
    private volatile string? _streamClientId; // client currently receiving the stream

    // ── Phase 6 Services ──
    private PortMonitorService? _portMonitor;
    private OpenClawService? _openClaw;
    private UltraContextSync? _ultraContext;
    private NotificationService? _notifications;
    private SystemIntegration? _systemIntegration;

    /// <summary>
    /// Returns true if a saved session exists and is loaded.
    /// </summary>
    public async Task<bool> HasSession()
    {
        var token = await _auth.LoadSession();
        return !string.IsNullOrEmpty(token);
    }

    /// <summary>
    /// Sign in with email/password. Returns null on success, error message on failure.
    /// </summary>
    public async Task<string?> SignIn(string email, string password)
    {
        var token = await _auth.SignIn(email, password);
        if (string.IsNullOrEmpty(token))
            return "invalid email or password";
        return null;
    }

    /// <summary>
    /// Sign in with GitHub OAuth. Returns null on success, error message on failure.
    /// </summary>
    public async Task<string?> SignInWithGitHub()
    {
        var token = await _auth.SignInWithGitHub();
        if (string.IsNullOrEmpty(token))
            return "github authentication failed";
        return null;
    }

    public async Task Start()
    {
        _cts = new CancellationTokenSource();

        // 1. Authenticate
        var token = _auth.AccessToken ?? await _auth.LoadSession();
        if (string.IsNullOrEmpty(token))
        {
            Console.WriteLine("[Daemon] No session — waiting for sign-in");
            return;
        }

        // 2. Register machine
        await _machine.Register(_auth);

        // 3. Initialize services
        _terminals = new TerminalSessionManager(
            onOutput: (sessionId, data) =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.TerminalOutput, new()
                {
                    ["sessionId"] = sessionId,
                    ["data"] = data,
                }));
            },
            onExit: (sessionId) =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.TerminalClose, new()
                {
                    ["sessionId"] = sessionId,
                }));
            }
        );

        _screenCapture = new ScreenCaptureService(onFrame: (frameData, isKeyframe) =>
        {
            if (_streamClientId != null)
            {
                _ = SendBinaryFrame(frameData, isKeyframe, _streamClientId);
            }
        });

        // 4. Initialize Phase 6 services
        _portMonitor = new PortMonitorService(
            onOutput: (workspacePath, data) =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.DevServerStatus, new()
                {
                    ["workspacePath"] = workspacePath,
                    ["data"] = data,
                }));
            },
            onStateChanged: (workspacePath, port, state) =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.DevServerStatus, new()
                {
                    ["workspacePath"] = workspacePath,
                    ["port"] = port?.ToString() ?? "",
                    ["state"] = state,
                }));
            }
        );
        _portMonitor.SetTerminalManager(_terminals!);

        _openClaw = new OpenClawService(
            onOutput: (text) =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.OpenclawOutput, new()
                {
                    ["data"] = text,
                }));
            },
            onComplete: () =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.OpenclawComplete, new()));
            },
            onError: (msg) =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.Error, new()
                {
                    ["message"] = $"OpenClaw: {msg}",
                }));
            }
        );

        _ultraContext = new UltraContextSync(
            onStatusUpdate: (key, value) =>
            {
                Console.WriteLine($"[UltraContext] {key}: {value}");
            }
        );

        _notifications = new NotificationService();

        _systemIntegration = new SystemIntegration(
            onWake: () =>
            {
                Console.WriteLine("[Daemon] Wake — re-acquiring resources");
                SleepPrevention.Prevent();
                _ = Task.Run(async () =>
                {
                    await _machine.Heartbeat(_auth);
                    var newToken = await _auth.RefreshToken();
                    if (newToken != null) _relay?.UpdateToken(newToken);
                    if (_relay != null) await _relay.Connect();
                });
            },
            onSleep: () =>
            {
                Console.WriteLine("[Daemon] Sleep — pausing");
            }
        );
        _systemIntegration.Start();

        // 5. Start LAN WebSocket server
        _lanServer = new WebSocketServer(HandlePacket);
        _ = _lanServer.Start(_cts.Token);

        // 6. Connect to relay
        _relay = new RelayClient(
            token: token,
            machineSecret: _machine.Secret,
            onPacket: HandlePacket,
            tokenRefresher: _auth.RefreshToken
        );
        await _relay.Connect();

        // 7. Start heartbeat (30s)
        _heartbeatTimer = new System.Threading.Timer(
            _ => Task.Run(async () =>
            {
                try { await _machine.Heartbeat(_auth); }
                catch (Exception ex) { Console.WriteLine($"[Heartbeat] Error: {ex.Message}"); }
            }),
            null,
            TimeSpan.Zero,
            TimeSpan.FromSeconds(30)
        );

        // 8. Start token refresh (45 min)
        _tokenRefreshTimer = new System.Threading.Timer(
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

        // 9. Prevent sleep
        SleepPrevention.Prevent();

        // 10. Detect agents and report
        _ = Task.Run(async () =>
        {
            var agents = await AgentDetector.DetectAll();
            Console.WriteLine($"[Daemon] Detected {agents.Count} agent(s): {string.Join(", ", agents.Select(a => a.Name))}");
        });

        Console.WriteLine("[Daemon] Started successfully");
    }

    public async Task Stop()
    {
        _heartbeatTimer?.Dispose();
        _tokenRefreshTimer?.Dispose();

        _screenCapture?.Stop();
        _screenCapture?.Dispose();
        _terminals?.Dispose();

        foreach (var (_, engine) in _engineSessions)
            engine.Dispose();
        _engineSessions.Clear();

        _portMonitor?.Dispose();
        _openClaw?.Dispose();
        _ultraContext?.Dispose();
        _notifications?.Dispose();
        _systemIntegration?.Dispose();

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

    // ── Packet Dispatch ──

    private async Task HandlePacket(WSPacket packet, string clientId)
    {
        Console.WriteLine($"[Daemon] {packet.Action} from {clientId}");

        try
        {
            switch (packet.Action)
            {
                // ── System ──
                case WSAction.Ping:
                    await SendToClient(WSPacket.Create(WSAction.Pong), clientId);
                    break;
                case WSAction.Pong:
                    break;

                // ── Stream ──
                case WSAction.StreamStart:
                    HandleStreamStart(packet, clientId);
                    break;
                case WSAction.StreamStop:
                    HandleStreamStop();
                    break;
                case WSAction.ScreenshotRequest:
                    await HandleScreenshot(clientId);
                    break;

                // ── Remote Input ──
                case WSAction.RemoteTap:
                    await HandleRemoteTap(packet);
                    break;
                case WSAction.RemoteDoubleTap:
                    await HandleRemoteDoubleTap(packet);
                    break;
                case WSAction.RemoteLongPress:
                    await HandleRemoteLongPress(packet);
                    break;
                case WSAction.RemoteScroll:
                    HandleRemoteScroll(packet);
                    break;
                case WSAction.RemoteDrag:
                    await HandleRemoteDrag(packet);
                    break;
                case WSAction.RemoteKeyboard:
                    await HandleRemoteKeyboard(packet);
                    break;

                // ── Terminal ──
                case WSAction.TerminalCreate:
                    HandleTerminalCreate(packet, clientId);
                    break;
                case WSAction.TerminalInput:
                    HandleTerminalInput(packet);
                    break;
                case WSAction.TerminalClose:
                    HandleTerminalClose(packet);
                    break;
                case WSAction.TerminalList:
                    await HandleTerminalList(clientId);
                    break;
                case WSAction.TerminalInterrupt:
                    HandleTerminalInterrupt(packet);
                    break;

                // ── Engine (Generic multi-provider) ──
                case WSAction.EngineCreate:
                    await HandleEngineCreate(packet, clientId);
                    break;
                case WSAction.EngineMessage:
                    await HandleEngineMessage(packet);
                    break;
                case WSAction.EngineUserResponse:
                    await HandleEngineUserResponse(packet);
                    break;
                case WSAction.EngineClose:
                    HandleEngineClose(packet);
                    break;
                case WSAction.EngineInterrupt:
                    HandleEngineInterrupt(packet);
                    break;

                // ── Claude Code (dedicated) ──
                case WSAction.ClaudeCreate:
                    await HandleClaudeCreate(packet, clientId);
                    break;
                case WSAction.ClaudeMessage:
                    await HandleClaudeMessage(packet);
                    break;
                case WSAction.ClaudeUserResponse:
                    await HandleClaudeUserResponse(packet);
                    break;
                case WSAction.ClaudeClose:
                    HandleClaudeClose(packet);
                    break;

                // ── Git ──
                case WSAction.GitCheckpoint:
                    await HandleGitCheckpoint(packet, clientId);
                    break;
                case WSAction.GitDiff:
                    await HandleGitDiff(packet, clientId);
                    break;
                case WSAction.GitRollback:
                    await HandleGitRollback(packet, clientId);
                    break;
                case WSAction.GitHistory:
                    await HandleGitHistory(packet, clientId);
                    break;
                case WSAction.GitFileDiff:
                    await HandleGitFileDiff(packet, clientId);
                    break;
                case WSAction.GitBranches:
                    await HandleGitBranches(packet, clientId);
                    break;
                case WSAction.GitCheckout:
                    await HandleGitCheckout(packet, clientId);
                    break;
                case WSAction.GitPull:
                    await HandleGitPull(packet, clientId);
                    break;
                case WSAction.GitStage:
                    await HandleGitStage(packet, clientId);
                    break;
                case WSAction.GitDiscard:
                    await HandleGitDiscard(packet, clientId);
                    break;

                // ── File Explorer ──
                case WSAction.FileTree:
                    await HandleFileTree(packet, clientId);
                    break;
                case WSAction.FileRead:
                    await HandleFileRead(packet, clientId);
                    break;

                // ── Workspace ──
                case WSAction.WorkspaceScanRepos:
                    await HandleWorkspaceScanRepos(clientId);
                    break;

                // ── Agents ──
                case WSAction.AgentsDetected:
                    await HandleAgentsDetected(clientId);
                    break;

                // ── DevTools ──
                case WSAction.ProcessList:
                    await HandleProcessList(clientId);
                    break;
                case WSAction.PortsList:
                    await HandlePortsList(clientId);
                    break;
                case WSAction.SystemResources:
                    await HandleSystemResources(clientId);
                    break;
                case WSAction.ProcessKill:
                    await HandleProcessKill(packet, clientId);
                    break;

                // ── Dev Server (W14) ──
                case WSAction.DevServerStart:
                    await HandleDevServerStart(packet, clientId);
                    break;
                case WSAction.DevServerStop:
                    await HandleDevServerStop(packet, clientId);
                    break;
                case WSAction.DevServerStatus:
                    await HandleDevServerStatus(packet, clientId);
                    break;
                case WSAction.ProxyDetectPorts:
                    await HandleDetectPorts(clientId);
                    break;

                // ── Sudo / UAC (W15) ──
                case WSAction.SudoRequest:
                    await HandleSudoRequest(packet, clientId);
                    break;

                // ── OpenClaw (W16) ──
                case WSAction.OpenclawStatus:
                    await HandleOpenClawStatus(clientId);
                    break;
                case WSAction.OpenclawMessage:
                    await HandleOpenClawMessage(packet);
                    break;

                // ── UltraContext (W16) ──
                case WSAction.UltracontextStatus:
                    await HandleUltraContextStatus(clientId);
                    break;

                // ── MCP (W16) ──
                case WSAction.McpList:
                    await HandleMcpList(clientId);
                    break;
                case WSAction.McpHealthCheck:
                    await HandleMcpHealthCheck(clientId);
                    break;

                default:
                    await SendToClient(
                        WSPacket.Create(WSAction.Error, new()
                        {
                            ["message"] = $"Unhandled action: {packet.Action}",
                        }),
                        clientId
                    );
                    break;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Daemon] Error handling {packet.Action}: {ex.Message}");
            await SendToClient(
                WSPacket.Create(WSAction.Error, new()
                {
                    ["message"] = $"Error: {ex.Message}",
                    ["action"] = packet.Action,
                }),
                clientId
            );
        }
    }

    // ════════════════════════════════════════════════
    // ── Stream Handlers ──
    // ════════════════════════════════════════════════

    private void HandleStreamStart(WSPacket packet, string clientId)
    {
        _streamClientId = clientId;
        var isLan = clientId != "relay";
        _screenCapture?.Start(isLan);
    }

    private void HandleStreamStop()
    {
        _screenCapture?.Stop();
        _streamClientId = null;
    }

    private async Task HandleScreenshot(string clientId)
    {
        var jpegBytes = _screenCapture?.TakeScreenshot();
        if (jpegBytes != null)
        {
            // Send as binary with "SCRN" prefix
            var frame = new byte[4 + jpegBytes.Length];
            Encoding.ASCII.GetBytes("SCRN", 0, 4, frame, 0);
            Buffer.BlockCopy(jpegBytes, 0, frame, 4, jpegBytes.Length);

            await SendBinaryToClient(frame, clientId);
        }
    }

    // ════════════════════════════════════════════════
    // ── Remote Input Handlers ──
    // ════════════════════════════════════════════════

    private static async Task HandleRemoteTap(WSPacket packet)
    {
        if (TryGetCoords(packet, out var x, out var y))
            await RemoteInputService.Tap(x, y);
    }

    private static async Task HandleRemoteDoubleTap(WSPacket packet)
    {
        if (TryGetCoords(packet, out var x, out var y))
            await RemoteInputService.DoubleTap(x, y);
    }

    private static async Task HandleRemoteLongPress(WSPacket packet)
    {
        if (TryGetCoords(packet, out var x, out var y))
            await RemoteInputService.LongPress(x, y);
    }

    private static void HandleRemoteScroll(WSPacket packet)
    {
        if (TryGetCoords(packet, out var x, out var y))
        {
            var deltaX = GetDouble(packet, "deltaX");
            var deltaY = GetDouble(packet, "deltaY");
            RemoteInputService.Scroll(x, y, deltaX, deltaY);
        }
    }

    private static async Task HandleRemoteDrag(WSPacket packet)
    {
        var startX = GetDouble(packet, "startX");
        var startY = GetDouble(packet, "startY");
        var endX = GetDouble(packet, "endX");
        var endY = GetDouble(packet, "endY");
        await RemoteInputService.Drag(startX, startY, endX, endY);
    }

    private static async Task HandleRemoteKeyboard(WSPacket packet)
    {
        var text = packet.Payload?.GetValueOrDefault("text", "");
        if (!string.IsNullOrEmpty(text))
            await RemoteInputService.TypeText(text);
    }

    // ════════════════════════════════════════════════
    // ── Terminal Handlers ──
    // ════════════════════════════════════════════════

    private void HandleTerminalCreate(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory");
        var sessionId = _terminals!.Create(workDir);

        _ = SendToClient(WSPacket.Create(WSAction.TerminalCreate, new()
        {
            ["sessionId"] = sessionId,
        }), clientId);
    }

    private void HandleTerminalInput(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        var data = packet.Payload?.GetValueOrDefault("data", "");
        if (sessionId != null && data != null)
            _terminals?.SendInput(sessionId, data);
    }

    private void HandleTerminalClose(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        if (sessionId != null)
            _terminals?.Close(sessionId);
    }

    private async Task HandleTerminalList(string clientId)
    {
        var sessions = _terminals?.ListSessions() ?? new();
        await SendToClient(WSPacket.Create(WSAction.TerminalList, new()
        {
            ["sessions"] = JsonSerializer.Serialize(sessions),
        }), clientId);
    }

    private void HandleTerminalInterrupt(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        if (sessionId != null)
            _terminals?.Interrupt(sessionId);
    }

    // ════════════════════════════════════════════════
    // ── Engine Handlers (Generic) ──
    // ════════════════════════════════════════════════

    private async Task HandleEngineCreate(WSPacket packet, string clientId)
    {
        var engineType = packet.Payload?.GetValueOrDefault("engineType", "");
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        var model = packet.Payload?.GetValueOrDefault("model");

        if (string.IsNullOrEmpty(engineType) || string.IsNullOrEmpty(workDir))
        {
            await SendToClient(WSPacket.Create(WSAction.EngineError, new()
            {
                ["message"] = "Missing engineType or workingDirectory",
            }), clientId);
            return;
        }

        var sessionId = Guid.NewGuid().ToString();

        // Find the agent binary
        var agents = await AgentDetector.DetectAll();
        var agent = agents.FirstOrDefault(a => a.Name == engineType);
        if (agent == null)
        {
            await SendToClient(WSPacket.Create(WSAction.EngineError, new()
            {
                ["message"] = $"Agent not found: {engineType}",
            }), clientId);
            return;
        }

        var engine = GenericCLIEngine.CreateForAgent(
            sessionId, engineType, agent.Path,
            onOutput: (sid, text) =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.EngineOutput, new()
                {
                    ["sessionId"] = sid,
                    ["data"] = text,
                }));
            },
            onComplete: (sid) =>
            {
                _engineSessions.TryRemove(sid, out _);
                _ = BroadcastPacket(WSPacket.Create(WSAction.EngineComplete, new()
                {
                    ["sessionId"] = sid,
                }));
            }
        );

        if (engine == null)
        {
            await SendToClient(WSPacket.Create(WSAction.EngineError, new()
            {
                ["message"] = $"Failed to create engine: {engineType}",
            }), clientId);
            return;
        }

        _engineSessions.TryAdd(sessionId, engine);
        await engine.Start(workDir, model);

        await SendToClient(WSPacket.Create(WSAction.EngineCreate, new()
        {
            ["sessionId"] = sessionId,
            ["engineType"] = engineType,
        }), clientId);
    }

    private async Task HandleEngineMessage(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        var message = packet.Payload?.GetValueOrDefault("message", "");
        if (sessionId != null && _engineSessions.TryGetValue(sessionId, out var engine))
            await engine.SendMessage(message ?? "");
    }

    private async Task HandleEngineUserResponse(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        var response = packet.Payload?.GetValueOrDefault("response", "");
        if (sessionId != null && _engineSessions.TryGetValue(sessionId, out var engine))
            await engine.RespondToQuestion(response ?? "");
    }

    private void HandleEngineClose(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        if (sessionId != null && _engineSessions.TryRemove(sessionId, out var engine))
            engine.Dispose();
    }

    private void HandleEngineInterrupt(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        if (sessionId != null && _engineSessions.TryGetValue(sessionId, out var engine))
            engine.Interrupt();
    }

    // ════════════════════════════════════════════════
    // ── Claude Code Handlers (Dedicated) ──
    // ════════════════════════════════════════════════

    private async Task HandleClaudeCreate(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        var model = packet.Payload?.GetValueOrDefault("model");

        if (string.IsNullOrEmpty(workDir))
        {
            await SendToClient(WSPacket.Create(WSAction.EngineError, new()
            {
                ["message"] = "Missing workingDirectory",
            }), clientId);
            return;
        }

        var sessionId = Guid.NewGuid().ToString();
        var session = new ClaudeCodeSession(
            sessionId,
            onOutput: (sid, line) =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.ClaudeOutput, new()
                {
                    ["sessionId"] = sid,
                    ["data"] = line,
                }));
            },
            onComplete: (sid) =>
            {
                _engineSessions.TryRemove(sid, out _);
                _ = BroadcastPacket(WSPacket.Create(WSAction.ClaudeComplete, new()
                {
                    ["sessionId"] = sid,
                }));
            },
            onAskUser: (sid, questionJson) =>
            {
                _ = BroadcastPacket(WSPacket.Create(WSAction.ClaudeAskUser, new()
                {
                    ["sessionId"] = sid,
                    ["data"] = questionJson,
                }));
            }
        );

        _engineSessions.TryAdd(sessionId, session);

        try
        {
            await session.Start(workDir, model);
            await SendToClient(WSPacket.Create(WSAction.ClaudeCreate, new()
            {
                ["sessionId"] = sessionId,
            }), clientId);
        }
        catch (Exception ex)
        {
            _engineSessions.TryRemove(sessionId, out _);
            session.Dispose();
            await SendToClient(WSPacket.Create(WSAction.EngineError, new()
            {
                ["message"] = $"Failed to start Claude Code: {ex.Message}",
            }), clientId);
        }
    }

    private async Task HandleClaudeMessage(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        var message = packet.Payload?.GetValueOrDefault("message", "");
        if (sessionId != null && _engineSessions.TryGetValue(sessionId, out var engine))
            await engine.SendMessage(message ?? "");
    }

    private async Task HandleClaudeUserResponse(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        var response = packet.Payload?.GetValueOrDefault("response", "");
        if (sessionId != null && _engineSessions.TryGetValue(sessionId, out var engine))
            await engine.RespondToQuestion(response ?? "");
    }

    private void HandleClaudeClose(WSPacket packet)
    {
        var sessionId = packet.Payload?.GetValueOrDefault("sessionId", "");
        if (sessionId != null && _engineSessions.TryRemove(sessionId, out var engine))
            engine.Dispose();
    }

    // ════════════════════════════════════════════════
    // ── Git Handlers ──
    // ════════════════════════════════════════════════

    private async Task HandleGitCheckpoint(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        var label = packet.Payload?.GetValueOrDefault("label", "pre-agent");
        if (workDir == null) return;

        var (success, message) = await GitService.Checkpoint(workDir, label ?? "pre-agent");
        await SendToClient(WSPacket.Create(WSAction.GitCheckpointResult, new()
        {
            ["success"] = success.ToString(),
            ["message"] = message,
        }), clientId);
    }

    private async Task HandleGitDiff(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        if (workDir == null) return;

        var diff = await GitService.Diff(workDir);
        await SendToClient(WSPacket.Create(WSAction.GitDiffResult, new()
        {
            ["diff"] = diff,
        }), clientId);
    }

    private async Task HandleGitRollback(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        var commitHash = packet.Payload?.GetValueOrDefault("commitHash", "");
        if (workDir == null || commitHash == null) return;

        var (success, message) = await GitService.Rollback(workDir, commitHash);
        await SendToClient(WSPacket.Create(WSAction.GitRollbackResult, new()
        {
            ["success"] = success.ToString(),
            ["message"] = message,
        }), clientId);
    }

    private async Task HandleGitHistory(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        if (workDir == null) return;

        var history = await GitService.History(workDir);
        await SendToClient(WSPacket.Create(WSAction.GitHistoryResult, new()
        {
            ["history"] = history,
        }), clientId);
    }

    private async Task HandleGitFileDiff(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        var filePath = packet.Payload?.GetValueOrDefault("filePath", "");
        if (workDir == null || filePath == null) return;

        var diff = await GitService.FileDiff(workDir, filePath);
        await SendToClient(WSPacket.Create(WSAction.GitFileDiffResult, new()
        {
            ["diff"] = diff,
        }), clientId);
    }

    private async Task HandleGitBranches(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        if (workDir == null) return;

        var branches = await GitService.Branches(workDir);
        await SendToClient(WSPacket.Create(WSAction.GitBranchesResult, new()
        {
            ["branches"] = branches,
        }), clientId);
    }

    private async Task HandleGitCheckout(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        var branch = packet.Payload?.GetValueOrDefault("branch", "");
        if (workDir == null || branch == null) return;

        var (success, message) = await GitService.Checkout(workDir, branch);
        await SendToClient(WSPacket.Create(WSAction.GitCheckoutResult, new()
        {
            ["success"] = success.ToString(),
            ["message"] = message,
        }), clientId);
    }

    private async Task HandleGitPull(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        if (workDir == null) return;

        var (success, message) = await GitService.Pull(workDir);
        await SendToClient(WSPacket.Create(WSAction.GitPullResult, new()
        {
            ["success"] = success.ToString(),
            ["message"] = message,
        }), clientId);
    }

    private async Task HandleGitStage(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        var filesJson = packet.Payload?.GetValueOrDefault("files", "[]");
        if (workDir == null) return;

        var files = JsonSerializer.Deserialize<string[]>(filesJson ?? "[]") ?? Array.Empty<string>();
        var (success, message) = await GitService.Stage(workDir, files);
        await SendToClient(WSPacket.Create(WSAction.GitStageResult, new()
        {
            ["success"] = success.ToString(),
            ["message"] = message,
        }), clientId);
    }

    private async Task HandleGitDiscard(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        var filesJson = packet.Payload?.GetValueOrDefault("files", "[]");
        if (workDir == null) return;

        var files = JsonSerializer.Deserialize<string[]>(filesJson ?? "[]") ?? Array.Empty<string>();
        var (success, message) = await GitService.Discard(workDir, files);
        await SendToClient(WSPacket.Create(WSAction.GitDiscardResult, new()
        {
            ["success"] = success.ToString(),
            ["message"] = message,
        }), clientId);
    }

    // ════════════════════════════════════════════════
    // ── File Explorer Handlers ──
    // ════════════════════════════════════════════════

    private async Task HandleFileTree(WSPacket packet, string clientId)
    {
        var path = packet.Payload?.GetValueOrDefault("path", "");
        if (string.IsNullOrEmpty(path)) return;

        var tree = FileService.GetFileTree(path);
        await SendToClient(WSPacket.Create(WSAction.FileTreeResult, new()
        {
            ["tree"] = JsonSerializer.Serialize(tree),
            ["path"] = path,
        }), clientId);
    }

    private async Task HandleFileRead(WSPacket packet, string clientId)
    {
        var path = packet.Payload?.GetValueOrDefault("path", "");
        if (string.IsNullOrEmpty(path)) return;

        var (content, isBinary, size) = FileService.ReadFile(path);
        await SendToClient(WSPacket.Create(WSAction.FileReadResult, new()
        {
            ["path"] = path,
            ["content"] = content ?? "",
            ["isBinary"] = isBinary.ToString(),
            ["size"] = size.ToString(),
        }), clientId);
    }

    // ════════════════════════════════════════════════
    // ── Workspace Handlers ──
    // ════════════════════════════════════════════════

    private async Task HandleWorkspaceScanRepos(string clientId)
    {
        var repos = await WorkspaceOrchestrator.ScanRepos();
        await SendToClient(WSPacket.Create(WSAction.WorkspaceScanResult, new()
        {
            ["repos"] = JsonSerializer.Serialize(repos),
        }), clientId);
    }

    // ════════════════════════════════════════════════
    // ── Agent Detection ──
    // ════════════════════════════════════════════════

    private async Task HandleAgentsDetected(string clientId)
    {
        var agents = await AgentDetector.DetectAll();
        var agentList = agents.Select(a => new Dictionary<string, string>
        {
            ["name"] = a.Name,
            ["path"] = a.Path,
            ["version"] = a.Version ?? "unknown",
        }).ToList();

        await SendToClient(WSPacket.Create(WSAction.AgentsDetected, new()
        {
            ["agents"] = JsonSerializer.Serialize(agentList),
        }), clientId);
    }

    // ════════════════════════════════════════════════
    // ── DevTools Handlers ──
    // ════════════════════════════════════════════════

    private async Task HandleProcessList(string clientId)
    {
        var allProcesses = System.Diagnostics.Process.GetProcesses();
        try
        {
            var processes = allProcesses
                .Where(p =>
                {
                    try { return !string.IsNullOrEmpty(p.MainWindowTitle) || p.WorkingSet64 > 50_000_000; }
                    catch { return false; }
                })
                .Take(100)
                .Select(p =>
                {
                    try
                    {
                        return new Dictionary<string, string>
                        {
                            ["pid"] = p.Id.ToString(),
                            ["name"] = p.ProcessName,
                            ["memory"] = (p.WorkingSet64 / 1_048_576).ToString(), // MB
                            ["title"] = p.MainWindowTitle ?? "",
                        };
                    }
                    catch { return null; }
                })
                .Where(p => p != null)
                .ToList();

            await SendToClient(WSPacket.Create(WSAction.ProcessListResult, new()
            {
                ["processes"] = JsonSerializer.Serialize(processes),
            }), clientId);
        }
        finally
        {
            foreach (var p in allProcesses) p.Dispose();
        }
    }

    private async Task HandlePortsList(string clientId)
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo
            {
                FileName = "netstat.exe",
                Arguments = "-ano",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var process = System.Diagnostics.Process.Start(psi);
            var output = await process!.StandardOutput.ReadToEndAsync();
            process.WaitForExit(5000);

            await SendToClient(WSPacket.Create(WSAction.PortsListResult, new()
            {
                ["ports"] = output,
            }), clientId);
        }
        catch (Exception ex)
        {
            await SendToClient(WSPacket.Create(WSAction.PortsListResult, new()
            {
                ["ports"] = $"Error: {ex.Message}",
            }), clientId);
        }
    }

    private async Task HandleSystemResources(string clientId)
    {
        var proc = System.Diagnostics.Process.GetCurrentProcess();
        await SendToClient(WSPacket.Create(WSAction.SystemResourcesResult, new()
        {
            ["cpuCount"] = Environment.ProcessorCount.ToString(),
            ["totalMemory"] = (GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 1_048_576).ToString(),
            ["tarsyMemory"] = (proc.WorkingSet64 / 1_048_576).ToString(),
            ["osVersion"] = Environment.OSVersion.ToString(),
            ["machineName"] = Environment.MachineName,
        }), clientId);
    }

    private async Task HandleProcessKill(WSPacket packet, string clientId)
    {
        var pidStr = packet.Payload?.GetValueOrDefault("pid", "");
        if (string.IsNullOrEmpty(pidStr) || !int.TryParse(pidStr, out var pid))
        {
            await SendToClient(WSPacket.Create(WSAction.ProcessKillResult, new()
            {
                ["success"] = "false",
                ["message"] = "Invalid PID",
            }), clientId);
            return;
        }

        // Refuse system PIDs and the current process
        var currentPid = Environment.ProcessId;
        if (pid == 0 || pid == 4 || pid == currentPid)
        {
            await SendToClient(WSPacket.Create(WSAction.ProcessKillResult, new()
            {
                ["success"] = "false",
                ["message"] = $"Refusing to kill protected PID {pid}",
            }), clientId);
            return;
        }

        try
        {
            using var proc = System.Diagnostics.Process.GetProcessById(pid);
            proc.Kill(entireProcessTree: true);
            await SendToClient(WSPacket.Create(WSAction.ProcessKillResult, new()
            {
                ["success"] = "true",
                ["message"] = $"Killed process {pid}",
            }), clientId);
        }
        catch (Exception ex)
        {
            await SendToClient(WSPacket.Create(WSAction.ProcessKillResult, new()
            {
                ["success"] = "false",
                ["message"] = ex.Message,
            }), clientId);
        }
    }

    // ════════════════════════════════════════════════
    // ── Dev Server Handlers (W14) ──
    // ════════════════════════════════════════════════

    private async Task HandleDevServerStart(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        var command = packet.Payload?.GetValueOrDefault("command", "");
        if (string.IsNullOrEmpty(workDir) || string.IsNullOrEmpty(command))
        {
            await SendToClient(WSPacket.Create(WSAction.Error, new()
            {
                ["message"] = "Missing workingDirectory or command",
            }), clientId);
            return;
        }

        var (success, message, sessionId) = await _portMonitor!.StartDevServer(workDir, command);
        await SendToClient(WSPacket.Create(WSAction.DevServerStatus, new()
        {
            ["success"] = success.ToString(),
            ["message"] = message,
            ["sessionId"] = sessionId ?? "",
            ["workspacePath"] = workDir,
            ["state"] = success ? "starting" : "error",
        }), clientId);
    }

    private async Task HandleDevServerStop(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        if (string.IsNullOrEmpty(workDir)) return;

        var (success, message) = await _portMonitor!.StopDevServer(workDir);
        await SendToClient(WSPacket.Create(WSAction.DevServerStatus, new()
        {
            ["success"] = success.ToString(),
            ["message"] = message,
            ["workspacePath"] = workDir,
            ["state"] = success ? "stopped" : "error",
        }), clientId);
    }

    private async Task HandleDevServerStatus(WSPacket packet, string clientId)
    {
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        if (string.IsNullOrEmpty(workDir)) return;

        var status = _portMonitor!.GetDevServerStatus(workDir);
        await SendToClient(WSPacket.Create(WSAction.DevServerStatus, new()
        {
            ["workspacePath"] = workDir,
            ["state"] = status?["state"] ?? "stopped",
            ["port"] = status?["port"] ?? "",
            ["command"] = status?["command"] ?? "",
        }), clientId);
    }

    private async Task HandleDetectPorts(string clientId)
    {
        var ports = await PortMonitorService.DetectPorts();
        await SendToClient(WSPacket.Create(WSAction.ProxyDetectPortsResult, new()
        {
            ["ports"] = JsonSerializer.Serialize(ports),
        }), clientId);
    }

    // ════════════════════════════════════════════════
    // ── Sudo / UAC Handlers (W15) ──
    // ════════════════════════════════════════════════

    private async Task HandleSudoRequest(WSPacket packet, string clientId)
    {
        var command = packet.Payload?.GetValueOrDefault("command", "");
        var workDir = packet.Payload?.GetValueOrDefault("workingDirectory", "");
        if (string.IsNullOrEmpty(command))
        {
            await SendToClient(WSPacket.Create(WSAction.SudoResult, new()
            {
                ["success"] = "false",
                ["message"] = "Missing command",
            }), clientId);
            return;
        }

        var (success, output) = await PrivilegeManager.HandleSudoRequest(command, workDir ?? "");
        await SendToClient(WSPacket.Create(WSAction.SudoResult, new()
        {
            ["success"] = success.ToString(),
            ["output"] = output,
        }), clientId);
    }

    // ════════════════════════════════════════════════
    // ── OpenClaw Handlers (W16) ──
    // ════════════════════════════════════════════════

    private async Task HandleOpenClawStatus(string clientId)
    {
        var status = await _openClaw!.GetStatus();
        await SendToClient(WSPacket.Create(WSAction.OpenclawStatus, new()
        {
            ["status"] = JsonSerializer.Serialize(status),
        }), clientId);
    }

    private async Task HandleOpenClawMessage(WSPacket packet)
    {
        var message = packet.Payload?.GetValueOrDefault("message", "");
        var model = packet.Payload?.GetValueOrDefault("model");
        if (!string.IsNullOrEmpty(message))
            await _openClaw!.SendMessage(message, model);
    }

    // ════════════════════════════════════════════════
    // ── UltraContext Handlers (W16) ──
    // ════════════════════════════════════════════════

    private async Task HandleUltraContextStatus(string clientId)
    {
        var status = _ultraContext!.GetStatus();
        await SendToClient(WSPacket.Create(WSAction.UltracontextStatus, new()
        {
            ["status"] = status,
        }), clientId);
    }

    // ════════════════════════════════════════════════
    // ── MCP Handlers (W16) ──
    // ════════════════════════════════════════════════

    private async Task HandleMcpList(string clientId)
    {
        var configs = McpHealthService.DiscoverMcpConfigs();
        var list = configs.Select(c => new Dictionary<string, string>
        {
            ["name"] = c.Name,
            ["source"] = c.Source,
            ["type"] = c.Url != null ? "http" : "stdio",
            ["command"] = c.Command ?? "",
            ["url"] = c.Url ?? "",
        }).ToList();

        await SendToClient(WSPacket.Create(WSAction.McpListResult, new()
        {
            ["servers"] = JsonSerializer.Serialize(list),
        }), clientId);
    }

    private async Task HandleMcpHealthCheck(string clientId)
    {
        var results = await McpHealthService.ScanAndCheck();
        await SendToClient(WSPacket.Create(WSAction.McpHealthResult, new()
        {
            ["results"] = JsonSerializer.Serialize(results),
        }), clientId);
    }

    // ════════════════════════════════════════════════
    // ── Send Helpers ──
    // ════════════════════════════════════════════════

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

    private async Task BroadcastPacket(WSPacket packet)
    {
        if (_relay != null)
            await _relay.Send(packet);
        // LAN broadcast would go here if needed
    }

    private async Task SendBinaryFrame(byte[] frameData, bool isKeyframe, string clientId)
    {
        // Build binary frame: "H264" (4 bytes) + keyframe flag (1 byte) + data
        var frame = new byte[5 + frameData.Length];
        Encoding.ASCII.GetBytes("H264", 0, 4, frame, 0);
        frame[4] = isKeyframe ? (byte)0x01 : (byte)0x00;
        Buffer.BlockCopy(frameData, 0, frame, 5, frameData.Length);

        await SendBinaryToClient(frame, clientId);
    }

    private async Task SendBinaryToClient(byte[] data, string clientId)
    {
        if (clientId == "relay" && _relay != null)
        {
            await _relay.SendBinary(data);
        }
        else if (_lanServer != null)
        {
            await _lanServer.SendBinary(data, clientId);
        }
    }

    // ── Payload Helpers ──

    private static bool TryGetCoords(WSPacket packet, out double x, out double y)
    {
        x = GetDouble(packet, "x");
        y = GetDouble(packet, "y");
        return x >= 0 && y >= 0;
    }

    private static double GetDouble(WSPacket packet, string key)
    {
        var val = packet.Payload?.GetValueOrDefault(key, "0");
        return double.TryParse(val, System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var result) ? result : 0;
    }
}
