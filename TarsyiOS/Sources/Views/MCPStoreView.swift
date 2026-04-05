import SwiftUI
import TarsyShared

struct MCPStoreView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) var dismiss

    let workspacePath: String?

    @State private var mcps: [MCPEntry] = []
    @State private var healthStatus: [String: String] = [:] // name -> status
    @State private var isLoading = true

    /// MCPs grouped by engine type
    private var mcpsByEngine: [AIEngineType: [MCPEntry]] {
        Dictionary(grouping: mcps, by: { $0.engineType })
    }

    /// Engines that have MCPs configured (sorted by display name)
    private var enginesWithMCPs: [AIEngineType] {
        mcpsByEngine.keys.sorted { $0.displayName < $1.displayName }
    }

    /// Detected agents that support MCP but have none configured
    private var enginesWithoutMCPs: [AIEngineType] {
        let detected = connectionManager.detectedAgents
        let withMCPs = Set(enginesWithMCPs)
        return detected
            .filter { $0.supportsMCP && !withMCPs.contains($0) }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Detected agents that don't support MCP
    private var enginesNoSupport: [AIEngineType] {
        let detected = connectionManager.detectedAgents
        return detected.filter { !$0.supportsMCP }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(TarsyTheme.accentAmber)
                        Text("detecting integrations...")
                            .font(TarsyTheme.font(size: 12))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                } else if mcps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(TarsyTheme.font(size: 40))
                            .foregroundColor(TarsyTheme.textSecondary)
                        Text("No MCPs configured")
                            .font(TarsyTheme.monoFont)
                            .foregroundColor(TarsyTheme.textSecondary)
                        Text("Add MCPs to your agent configs\nand they'll appear here automatically")
                            .font(TarsyTheme.font(size: 11))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Engines with MCPs configured
                            ForEach(enginesWithMCPs, id: \.self) { engine in
                                engineSection(engine, mcps: mcpsByEngine[engine] ?? [])
                            }

                            // Engines without MCPs (but support them)
                            if !enginesWithoutMCPs.isEmpty {
                                ForEach(enginesWithoutMCPs, id: \.self) { engine in
                                    emptyEngineRow(engine, label: "no MCPs configured")
                                }
                            }

                            // Engines that don't support MCP
                            if !enginesNoSupport.isEmpty {
                                ForEach(enginesNoSupport, id: \.self) { engine in
                                    emptyEngineRow(engine, label: "not supported")
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("integrations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { dismiss() }
                        .foregroundColor(TarsyTheme.accentAmber)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { loadMCPs() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(TarsyTheme.font(size: 14))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { setupListeners(); loadMCPs() }
        .onDisappear { connectionManager.removeListener("mcp-store") }
    }

    // MARK: - Engine Section

    private func engineSection(_ engine: AIEngineType, mcps: [MCPEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentIcon(engineType: engine, size: 18)
                Text(engine.displayName)
                    .font(TarsyTheme.font(size: 13, weight: .semibold))
                    .foregroundColor(TarsyTheme.textPrimary)

                Spacer()

                Text("\(mcps.count) active")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)
            }

            VStack(spacing: 1) {
                ForEach(mcps) { mcp in
                    mcpRow(mcp)
                }
            }
            .cornerRadius(10)
        }
    }

    private func mcpRow(_ mcp: MCPEntry) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(healthColor(for: mcp.name))
                .frame(width: 8, height: 8)

            Image(systemName: mcpIcon(mcp.name))
                .font(TarsyTheme.font(size: 15))
                .foregroundColor(TarsyTheme.accentAmber)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(mcpDisplayName(mcp.name))
                    .font(TarsyTheme.font(size: 13))
                    .foregroundColor(TarsyTheme.textPrimary)

                HStack(spacing: 6) {
                    Text(mcp.type)
                        .font(TarsyTheme.font(size: 9))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(TarsyTheme.backgroundTertiary)
                        .cornerRadius(3)

                    if mcp.scope == "project" {
                        Text("project")
                            .font(TarsyTheme.font(size: 9))
                            .foregroundColor(TarsyTheme.accentAmber.opacity(0.8))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(TarsyTheme.accentAmber.opacity(0.1))
                            .cornerRadius(3)
                    }
                }
            }

            Spacer()

            Text(healthLabel(for: mcp.name))
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(healthColor(for: mcp.name))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(TarsyTheme.backgroundSecondary)
    }

    private func emptyEngineRow(_ engine: AIEngineType, label: String) -> some View {
        HStack(spacing: 8) {
            AgentIcon(engineType: engine, size: 16)
            Text(engine.displayName)
                .font(TarsyTheme.font(size: 13, weight: .semibold))
                .foregroundColor(TarsyTheme.textSecondary)
            Spacer()
            Text(label)
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(10)
    }

    // MARK: - Actions

    private func loadMCPs() {
        isLoading = true
        connectionManager.send(WSPacket(action: .mcpList, payload: workspacePath != nil ? ["path": workspacePath!] : nil))
    }

    private func setupListeners() {
        connectionManager.addListener("mcp-store") { [self] packet in
            Task { @MainActor in
                switch packet.action {
                case .mcpListResult:
                    isLoading = false
                    if let json = packet.payload?["mcps"],
                       let data = json.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                        mcps = parsed.map { MCPEntry(from: $0) }
                        // Auto health check all
                        for mcp in mcps {
                            connectionManager.send(WSPacket(action: .mcpHealthCheck, payload: [
                                "name": mcp.name,
                                "type": mcp.type,
                                "command": mcp.command
                            ]))
                        }
                    }

                case .mcpHealthResult:
                    if let name = packet.payload?["name"],
                       let status = packet.payload?["status"] {
                        healthStatus[name] = status
                    }

                default: break
                }
            }
        }
    }

    // MARK: - Display Helpers

    private func healthColor(for name: String) -> Color {
        switch healthStatus[name] {
        case "healthy": return Color(red: 0.133, green: 0.773, blue: 0.369)
        case "unreachable", "not_found": return TarsyTheme.accentTerracotta
        default: return TarsyTheme.textSecondary.opacity(0.5)
        }
    }

    private func healthLabel(for name: String) -> String {
        switch healthStatus[name] {
        case "healthy": return "connected"
        case "unreachable": return "unreachable"
        case "not_found": return "not found"
        default: return "checking..."
        }
    }

    private func mcpDisplayName(_ name: String) -> String {
        let cleanNames: [String: String] = [
            "context7": "Context7",
            "chrome-devtools": "Chrome DevTools",
            "MCP_DOCKER": "Docker",
            "posthog": "PostHog",
            "atlassian": "Atlassian (Jira)",
            "stripe": "Stripe",
            "firebase": "Firebase",
            "supabase": "Supabase",
            "github": "GitHub",
            "slack": "Slack",
            "linear": "Linear",
            "sentry": "Sentry",
            "figma": "Figma",
            "obsidian": "Obsidian",
            "playwright": "Playwright",
            "shadcn": "shadcn/ui",
        ]
        return cleanNames[name] ?? name.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func mcpIcon(_ name: String) -> String {
        let icons: [String: String] = [
            "github": "cat.circle",
            "chrome-devtools": "globe",
            "context7": "doc.text.magnifyingglass",
            "MCP_DOCKER": "shippingbox",
            "posthog": "chart.bar",
            "atlassian": "ticket",
            "stripe": "creditcard",
            "firebase": "flame",
            "supabase": "server.rack",
            "slack": "bubble.left.and.bubble.right",
            "linear": "line.3.horizontal",
            "sentry": "shield",
            "figma": "pencil.and.ruler",
            "obsidian": "note.text",
            "playwright": "theatermasks",
            "shadcn": "rectangle.3.group",
        ]
        return icons[name] ?? "puzzlepiece.extension"
    }
}

// MARK: - Model

struct MCPEntry: Identifiable {
    let id = UUID()
    let name: String
    let engine: String
    let scope: String
    let type: String
    let command: String

    var engineType: AIEngineType {
        AIEngineType(rawValue: engine) ?? .claude
    }

    init(from dict: [String: String]) {
        self.name = dict["name"] ?? ""
        self.engine = dict["engine"] ?? "claude"
        self.scope = dict["scope"] ?? "global"
        self.type = dict["type"] ?? "unknown"
        self.command = dict["command"] ?? ""
    }
}

#if DEBUG
#Preview {
    MCPStoreView(workspacePath: "/Users/dev/projects/tarsy")
        .environmentObject(ConnectionManager())
        .preferredColorScheme(.dark)
}
#endif
