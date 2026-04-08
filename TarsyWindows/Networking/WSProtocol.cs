using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TarsyWindows.Networking;

/// <summary>
/// All WebSocket protocol actions — mirrors WSProtocol.swift.
/// </summary>
public static class WSAction
{
    // System
    public const string Auth = "auth";
    public const string AuthSuccess = "auth:success";
    public const string AuthFail = "auth:fail";
    public const string Ping = "ping";
    public const string Pong = "pong";
    public const string Error = "error";

    // Workspace
    public const string WorkspaceList = "workspace:list";
    public const string WorkspaceCreate = "workspace:create";
    public const string WorkspaceStart = "workspace:start";
    public const string WorkspaceStop = "workspace:stop";
    public const string WorkspaceStatus = "workspace:status";
    public const string WorkspaceUpdate = "workspace:update";
    public const string WorkspaceScanRepos = "workspace:scan_repos";
    public const string WorkspaceScanResult = "workspace:scan_result";

    // Stream
    public const string StreamStart = "stream:start";
    public const string StreamStop = "stream:stop";
    public const string StreamFrame = "stream:frame";

    // Remote Input
    public const string RemoteTap = "remote:tap";
    public const string RemoteDoubleTap = "remote:double_tap";
    public const string RemoteLongPress = "remote:long_press";
    public const string RemoteScroll = "remote:scroll";
    public const string RemoteDrag = "remote:drag";
    public const string RemoteScrollStart = "remote:scroll_start";
    public const string RemoteScrollEnd = "remote:scroll_end";
    public const string RemotePinch = "remote:pinch";
    public const string RemotePinchStart = "remote:pinch_start";
    public const string RemotePinchEnd = "remote:pinch_end";
    public const string RemoteKeyboard = "remote:keyboard";
    public const string RemoteButton = "remote:button";
    public const string ScreenshotRequest = "screenshot:request";
    public const string ScreenshotResult = "screenshot:result";

    // Dev Server
    public const string DevServerStart = "devserver:start";
    public const string DevServerStop = "devserver:stop";
    public const string DevServerStatus = "devserver:status";

    // Browser
    public const string BrowserOpenUrl = "browser:open_url";
    public const string BrowserBack = "browser:back";
    public const string BrowserForward = "browser:forward";
    public const string BrowserRefresh = "browser:refresh";
    public const string BrowserMobileViewport = "browser:mobile_viewport";
    public const string BrowserDesktopViewport = "browser:desktop_viewport";
    public const string BrowserTabList = "browser:tab_list";
    public const string BrowserTabListResult = "browser:tab_list_result";
    public const string BrowserTabSwitch = "browser:tab_switch";
    public const string BrowserTabClose = "browser:tab_close";

    // HTTP Proxy
    public const string ProxyDetectPorts = "proxy:detect_ports";
    public const string ProxyDetectPortsResult = "proxy:detect_ports_result";
    public const string ProxyRequest = "proxy:request";
    public const string ProxyResponse = "proxy:response";

    // Terminal
    public const string TerminalCreate = "terminal:create";
    public const string TerminalInput = "terminal:input";
    public const string TerminalOutput = "terminal:output";
    public const string TerminalClose = "terminal:close";
    public const string TerminalList = "terminal:list";
    public const string TerminalComplete = "terminal:complete";
    public const string TerminalCompleteResult = "terminal:complete_result";
    public const string TerminalInterrupt = "terminal:interrupt";

    // Engine Interrupt
    public const string EngineInterrupt = "engine:interrupt";

    // Claude Code
    public const string ClaudeCreate = "claude:create";
    public const string ClaudeMessage = "claude:message";
    public const string ClaudeOutput = "claude:output";
    public const string ClaudeComplete = "claude:complete";
    public const string ClaudeClose = "claude:close";
    public const string ClaudeAskUser = "claude:ask_user";
    public const string ClaudeUserResponse = "claude:user_response";

    // OpenClaw
    public const string OpenclawStatus = "openclaw:status";
    public const string OpenclawMessage = "openclaw:message";
    public const string OpenclawOutput = "openclaw:output";
    public const string OpenclawComplete = "openclaw:complete";

    // Generic Engine (multi-provider)
    public const string EngineCreate = "engine:create";
    public const string EngineMessage = "engine:message";
    public const string EngineOutput = "engine:output";
    public const string EngineComplete = "engine:complete";
    public const string EngineClose = "engine:close";
    public const string EngineError = "engine:error";
    public const string EngineAskUser = "engine:ask_user";
    public const string EngineUserResponse = "engine:user_response";

    // Git
    public const string GitCheckpoint = "git:checkpoint";
    public const string GitCheckpointResult = "git:checkpoint_result";
    public const string GitDiff = "git:diff";
    public const string GitDiffResult = "git:diff_result";
    public const string GitRollback = "git:rollback";
    public const string GitRollbackResult = "git:rollback_result";
    public const string GitHistory = "git:history";
    public const string GitHistoryResult = "git:history_result";
    public const string GitFileDiff = "git:file_diff";
    public const string GitFileDiffResult = "git:file_diff_result";
    public const string GitBranches = "git:branches";
    public const string GitBranchesResult = "git:branches_result";
    public const string GitCheckout = "git:checkout";
    public const string GitCheckoutResult = "git:checkout_result";
    public const string GitPull = "git:pull";
    public const string GitPullResult = "git:pull_result";
    public const string GitStage = "git:stage";
    public const string GitStageResult = "git:stage_result";
    public const string GitDiscard = "git:discard";
    public const string GitDiscardResult = "git:discard_result";

    // File Explorer
    public const string FileTree = "file:tree";
    public const string FileTreeResult = "file:tree_result";
    public const string FileRead = "file:read";
    public const string FileReadResult = "file:read_result";

    // Engine Status
    public const string EngineStatus = "engine:status";

    // MCP Store
    public const string McpList = "mcp:list";
    public const string McpListResult = "mcp:list_result";
    public const string McpHealthCheck = "mcp:health_check";
    public const string McpHealthResult = "mcp:health_result";

    // Relay
    public const string RelayMachineOnline = "relay:machine_online";
    public const string RelayMachineOffline = "relay:machine_offline";
    public const string RelayStreamFrame = "relay:stream_frame";
    public const string RelayNoClients = "relay:no_clients";

    // Sudo / UAC
    public const string SudoRequest = "sudo:request";
    public const string SudoResponse = "sudo:response";
    public const string SudoResult = "sudo:result";

    // Agent Detection
    public const string AgentsDetected = "agents:detected";
    public const string SlashCommandsRequest = "agents:slash_commands_request";
    public const string SlashCommandsDetected = "agents:slash_commands";

    // Agent Settings
    public const string AgentSettings = "agent:settings";
    public const string AgentSettingsUpdate = "agent:settings_update";

    // Repo Analysis
    public const string RepoAnalyze = "repo:analyze";
    public const string RepoAnalysis = "repo:analysis";

    // AI Project Wizard
    public const string WizardStart = "wizard:start";
    public const string WizardResponse = "wizard:response";
    public const string WizardExecute = "wizard:execute";
    public const string WizardResult = "wizard:result";
    public const string WizardGhDetected = "wizard:gh_detected";

    // UltraContext
    public const string UltracontextStatus = "ultracontext:status";

    // DevTools
    public const string ProcessList = "devtools:process_list";
    public const string ProcessListResult = "devtools:process_list_result";
    public const string ProcessKill = "devtools:process_kill";
    public const string ProcessKillResult = "devtools:process_kill_result";
    public const string PortsList = "devtools:ports_list";
    public const string PortsListResult = "devtools:ports_list_result";
    public const string HttpRequest = "devtools:http_request";
    public const string HttpResponse = "devtools:http_response";
    public const string SystemResources = "devtools:system_resources";
    public const string SystemResourcesResult = "devtools:system_resources_result";

    // Security
    public const string SecurityRotateSecret = "security:rotate_machine_secret";
    public const string SecurityRotateResult = "security:rotate_result";
    public const string SecurityFingerprintUpdate = "security:fingerprint_update";
    public const string E2eEncrypted = "e2e:encrypted";
    public const string E2eKeyExchange = "e2e:key_exchange";
    public const string E2eKeyExchangeResponse = "e2e:key_exchange_response";
}

public record WSPacket
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = Guid.NewGuid().ToString();

    [JsonPropertyName("action")]
    public string Action { get; init; } = "";

    [JsonPropertyName("payload")]
    public Dictionary<string, string>? Payload { get; init; }

    [JsonPropertyName("timestamp")]
    public DateTime Timestamp { get; init; } = DateTime.UtcNow;

    public static WSPacket Create(string action, Dictionary<string, string>? payload = null)
    {
        return new WSPacket
        {
            Id = Guid.NewGuid().ToString(),
            Action = action,
            Payload = payload,
            Timestamp = DateTime.UtcNow,
        };
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public string Encode()
    {
        var json = JsonSerializer.Serialize(this, JsonOptions);
        if (json.Length > MaxPacketSize)
            throw new InvalidOperationException($"WSPacket too large: {json.Length} bytes (max {MaxPacketSize})");
        return json;
    }

    public static WSPacket Decode(string json)
    {
        if (json.Length > MaxPacketSize)
            throw new InvalidOperationException($"WSPacket too large: {json.Length} bytes (max {MaxPacketSize})");
        return JsonSerializer.Deserialize<WSPacket>(json, JsonOptions)
            ?? throw new InvalidOperationException("Failed to decode WSPacket");
    }

    private const int MaxPacketSize = 1_048_576; // 1 MB
}
