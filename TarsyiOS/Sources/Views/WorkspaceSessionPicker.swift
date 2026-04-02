import SwiftUI
import TarsyShared

/// Picker that shows UltraContext sessions matching the current workspace.
/// Presented from the "+" menu in WorkspaceView.
struct WorkspaceSessionPicker: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var client = UltraContextClient.configured()
    let workspace: Workspace
    let detectedAgents: [AIEngineType]
    let onSelect: (UltraContextSession, AIEngineType) -> Void

    @State private var selectedSession: UltraContextSession?
    @State private var loadedSession: UltraContextSession?
    @State private var isLoadingDetail = false
    @State private var showAgentPicker = false
    @State private var pendingSession: UltraContextSession?

    var filteredSessions: [UltraContextSession] {
        let wsId = workspace.id.uuidString
        return client.sessions.filter { session in
            guard session.title != "Untitled session" else { return false }
            // Primary: match by workspaceId (reliable for monorepos)
            if let sessionWsId = session.workspaceId {
                return sessionWsId.lowercased() == wsId.lowercased()
            }
            // Fallback: match by path (for sessions created before workspaceId was added)
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
                            .font(TarsyTheme.font(size: 48))
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await client.loadSessions() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(TarsyTheme.accentAmber)
                    }
                }
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
        .confirmationDialog("Choose agent", isPresented: $showAgentPicker, titleVisibility: .visible) {
            ForEach(detectedAgents, id: \.self) { engine in
                Button(engine.displayName) {
                    if var session = pendingSession {
                        session = UltraContextSession(
                            id: session.id,
                            messages: session.messages,
                            version: session.version,
                            createdAt: session.createdAt,
                            title: session.title,
                            hasImage: session.hasImage,
                            projectPath: session.projectPath,
                            engineType: engine.rawValue,
                            workspaceId: session.workspaceId,
                            messageCount: session.messageCount
                        )
                        onSelect(session, engine)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingSession = nil
            }
        } message: {
            Text("Which agent should continue this session?")
        }
    }

    private func sessionRow(_ session: UltraContextSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: session.hasImage ? "photo" : "brain.head.profile")
                .font(TarsyTheme.font(size: 16))
                .foregroundColor(session.hasImage ? TarsyTheme.accentTerracotta : TarsyTheme.accentAmber)
                .frame(width: 32, height: 32)
                .background((session.hasImage ? TarsyTheme.accentTerracotta : TarsyTheme.accentAmber).opacity(0.15))
                .cornerRadius(6)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(TarsyTheme.font(size: 12, weight: .medium))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let count = session.messageCount, count > 0 {
                        Text("\(count) msgs")
                            .font(TarsyTheme.font(size: 9))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                    if let created = session.createdAt {
                        Text(formatDate(created))
                            .font(TarsyTheme.font(size: 9))
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
                    .font(TarsyTheme.font(size: 10))
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
                workspaceId: session.workspaceId ?? full.workspaceId,
                messageCount: full.messages.count
            )
            pendingSession = enriched
            if detectedAgents.count <= 1 {
                let engine = detectedAgents.first ?? .claude
                let finalSession = UltraContextSession(
                    id: enriched.id,
                    messages: enriched.messages,
                    version: enriched.version,
                    createdAt: enriched.createdAt,
                    title: enriched.title,
                    hasImage: enriched.hasImage,
                    projectPath: enriched.projectPath,
                    engineType: engine.rawValue,
                    workspaceId: enriched.workspaceId,
                    messageCount: enriched.messageCount
                )
                onSelect(finalSession, engine)
            } else {
                showAgentPicker = true
            }
        } catch {
#if DEBUG
            print("[SessionPicker] Load error: \(error)")
#endif
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

#if DEBUG
#Preview {
    WorkspaceSessionPicker(
        workspace: PreviewData.workspace,
        detectedAgents: [.claude, .gemini],
        onSelect: { _, _ in }
    )
    .preferredColorScheme(.dark)
}
#endif
