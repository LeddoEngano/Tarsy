import SwiftUI
import TarsyShared

/// Picker that shows UltraContext sessions matching the current workspace.
/// Presented from the "+" menu in WorkspaceView.
struct WorkspaceSessionPicker: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var client = UltraContextClient.configured()
    let workspace: Workspace
    let onSelect: (UltraContextSession) -> Void

    @State private var selectedSession: UltraContextSession?
    @State private var loadedSession: UltraContextSession?
    @State private var isLoadingDetail = false

    var filteredSessions: [UltraContextSession] {
        client.sessions.filter { session in
            guard let path = session.projectPath else { return false }
            return workspace.localPath == path
                || path.hasPrefix(workspace.localPath)
                || workspace.localPath.hasPrefix(path)
                || workspace.localPath.components(separatedBy: "/").last == path.components(separatedBy: "/").last
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                if client.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(TarsyTheme.accentAmber)
                        Text("loading sessions...")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                } else if filteredSessions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 48))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))

                        Text("no previous sessions")
                            .font(TarsyTheme.monoFont)
                            .foregroundColor(TarsyTheme.textSecondary)

                        Text("Start a conversation first. Previous sessions for this workspace will appear here.")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredSessions) { session in
                                Button {
                                    Task { await loadAndSelect(session) }
                                } label: {
                                    sessionRow(session)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("previous sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("cancel") { dismiss() }
                        .foregroundColor(TarsyTheme.accentAmber)
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task {
            await client.loadSessions()
        }
    }

    private func sessionRow(_ session: UltraContextSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.hasImage ? "photo" : "brain.head.profile")
                .font(.system(size: 16))
                .foregroundColor(session.hasImage ? TarsyTheme.accentTerracotta : TarsyTheme.accentAmber)
                .frame(width: 32, height: 32)
                .background((session.hasImage ? TarsyTheme.accentTerracotta : TarsyTheme.accentAmber).opacity(0.15))
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let count = session.messageCount, count > 0 {
                        Text("\(count) msgs")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                    if let created = session.createdAt {
                        Text(formatDate(created))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }
            }

            Spacer()

            if isLoadingDetail && selectedSession?.id == session.id {
                ProgressView()
                    .scaleEffect(0.6)
                    .tint(TarsyTheme.accentAmber)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))
            }
        }
        .padding(10)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(8)
    }

    private func loadAndSelect(_ session: UltraContextSession) async {
        selectedSession = session
        isLoadingDetail = true
        do {
            let full = try await client.getContext(id: session.id)
            let enriched = UltraContextSession(
                id: full.id,
                messages: full.messages,
                version: full.version,
                createdAt: session.createdAt ?? full.createdAt,
                title: session.title ?? full.title,
                hasImage: session.hasImage,
                projectPath: session.projectPath ?? full.projectPath,
                engineType: session.engineType ?? full.engineType,
                messageCount: full.messages.count
            )
            onSelect(enriched)
        } catch {
            print("[SessionPicker] Load error: \(error)")
        }
        isLoadingDetail = false
    }

    private func formatDate(_ dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateStr) {
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: dateStr) {
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        return ""
    }
}
