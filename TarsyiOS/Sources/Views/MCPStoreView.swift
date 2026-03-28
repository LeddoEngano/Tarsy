import SwiftUI
import TarsyShared

struct MCPStoreView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) var dismiss

    let workspacePath: String?

    @State private var mcps: [MCPEntry] = []
    @State private var healthStatus: [String: String] = [:] // name -> status
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(TarsyTheme.accentAmber)
                        Text("detecting integrations...")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                } else if mcps.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 40))
                            .foregroundColor(TarsyTheme.textSecondary)
                        Text("No MCPs configured")
                            .font(TarsyTheme.monoFont)
                            .foregroundColor(TarsyTheme.textSecondary)
                        Text("Add MCPs to your ~/.claude.json\nand they'll appear here automatically")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Claude Code section
                            engineSection(.claude, mcps: mcps)

                            // Other engines placeholder
                            otherEnginesSection
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
                            .font(.system(size: 14))
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
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)

                Spacer()

                Text("\(mcps.count) active")
                    .font(.system(size: 10, design: .monospaced))
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
            // Health indicator
            Circle()
                .fill(healthColor(for: mcp.name))
                .frame(width: 8, height: 8)

            // Icon
            Image(systemName: mcpIcon(mcp.name))
                .font(.system(size: 15))
                .foregroundColor(TarsyTheme.accentAmber)
                .frame(width: 24)

            // Name + details
            VStack(alignment: .leading, spacing: 2) {
                Text(mcpDisplayName(mcp.name))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)

                HStack(spacing: 6) {
                    Text(mcp.type)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(TarsyTheme.backgroundTertiary)
                        .cornerRadius(3)

                    if mcp.scope == "project" {
                        Text("project")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(TarsyTheme.accentAmber.opacity(0.8))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(TarsyTheme.accentAmber.opacity(0.1))
                            .cornerRadius(3)
                    }
                }
            }

            Spacer()

            // Health status text
            Text(healthLabel(for: mcp.name))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(healthColor(for: mcp.name))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(TarsyTheme.backgroundSecondary)
    }

    private var otherEnginesSection: some View {
        let otherEngines: [AIEngineType] = [.gemini, .codex, .aider, .cursor, .windsurf, .amp, .cline, .copilot]
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(otherEngines, id: \.self) { engine in
                HStack(spacing: 8) {
                    AgentIcon(engineType: engine, size: 16)
                    Text(engine.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                    Spacer()
                    Text("no MCP support")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(10)
            }
        }
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
        case "healthy": return Color(red: 0.133, green: 0.773, blue: 0.369) // green-500
        case "unreachable", "not_found": return TarsyTheme.accentTerracotta
        default: return TarsyTheme.textSecondary.opacity(0.5) // checking
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
        // Clean up common MCP names
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
    let scope: String
    let type: String
    let command: String

    init(from dict: [String: String]) {
        self.name = dict["name"] ?? ""
        self.scope = dict["scope"] ?? "global"
        self.type = dict["type"] ?? "unknown"
        self.command = dict["command"] ?? ""
    }
}
