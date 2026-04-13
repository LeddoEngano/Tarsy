import SwiftUI
import TarsyShared

struct BuildRunView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager

    @Binding var buildOutput: [String]
    @Binding var buildPhase: String
    @Binding var buildPercent: Int
    @Binding var hotReloadStatus: String
    @Binding var hotReloadInjectionCount: Int
    @Binding var isBuildRunning: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Build button + status bar
            controlsSection

            // Progress bar
            if isBuildRunning {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(TarsyTheme.backgroundTertiary)
                        Rectangle()
                            .fill(TarsyTheme.accentAmber)
                            .frame(width: geo.size.width * CGFloat(buildPercent) / 100)
                            .animation(.easeInOut(duration: 0.3), value: buildPercent)
                    }
                }
                .frame(height: 3)
            }

            Divider().background(TarsyTheme.backgroundTertiary)

            // Build output log
            buildLogSection
        }
        .background(TarsyTheme.backgroundPrimary)
    }

    // MARK: - Controls

    private var controlsSection: some View {
        HStack(spacing: 12) {
            Button(action: startBuild) {
                HStack(spacing: 6) {
                    if isBuildRunning {
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(TarsyTheme.textPrimary)
                    } else {
                        Image(systemName: "hammer.fill")
                            .font(TarsyTheme.font(size: 12))
                    }
                    Text(isBuildRunning ? "building..." : "Build & Run")
                        .font(TarsyTheme.monoFont)
                }
                .foregroundColor(isBuildRunning ? TarsyTheme.textSecondary : TarsyTheme.backgroundPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(isBuildRunning ? TarsyTheme.backgroundTertiary : TarsyTheme.accentAmber)
                .cornerRadius(8)
            }
            .disabled(isBuildRunning)

            if hotReloadStatus != "idle" {
                HotReloadStatusBadge(
                    status: hotReloadStatus,
                    injectionCount: hotReloadInjectionCount
                )
            }

            Spacer()
        }
        .padding(16)
    }

    // MARK: - Build Log

    private var buildLogSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if buildOutput.isEmpty {
                    VStack(spacing: 8) {
                        Spacer().frame(height: 60)
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 32))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.3))
                        Text("tap Build & Run to start")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                        Text("scheme and simulator are auto-detected")
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.3))
                        Text("changes to .swift files will auto-reload")
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.3))
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(buildOutput.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(TarsyTheme.font(size: 11))
                                .foregroundColor(lineColor(for: line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
            }
            .onChange(of: buildOutput.count) { _ in
                if let last = buildOutput.indices.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func startBuild() {
        guard !isBuildRunning else { return }
        isBuildRunning = true
        buildOutput = ["Starting build..."]
        buildPhase = "preparing"
        buildPercent = 0
        hotReloadStatus = "idle"
        hotReloadInjectionCount = 0

        // Send with empty scheme — macOS will auto-detect
        connectionManager.send(WSPacket(
            action: .buildStart,
            payload: [
                "path": workspace.localPath,
                "scheme": "",
                "simulatorUDID": "",
                "configuration": "Debug"
            ]
        ))
    }

    private func lineColor(for line: String) -> Color {
        if line.hasPrefix("ERROR") || line.contains("error:") {
            return Color(red: 0.8, green: 0.3, blue: 0.3)
        }
        if line.hasPrefix("⚡") {
            return Color(red: 0.4, green: 0.8, blue: 0.4)
        }
        if line.hasPrefix("Simulator:") || line.hasPrefix("Starting") || line.hasPrefix("Using scheme") {
            return TarsyTheme.accentAmber
        }
        return TarsyTheme.textSecondary
    }
}
