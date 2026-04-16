import SwiftUI
import TarsyShared

struct ActiveSessionsView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var client = UltraContextClient.configured()
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @State private var selectedSession: UltraContextSession?
    @State private var loadedSession: UltraContextSession?
    @State private var isLoadingDetail = false

    // Edit mode
    @State private var isEditing = false
    @State private var selectedIds: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    // Workspace picker
    @State private var showWorkspacePicker = false
    @State private var pendingContinueSession: UltraContextSession?
    @State private var matchedWorkspaces: [Workspace] = []

    // No workspace found
    @State private var showNoWorkspaceAlert = false
    @State private var showNewWorkspace = false
    @State private var showPaywall = false

    private var visibleSessions: [UltraContextSession] {
        client.sessions.filter { $0.title != "Untitled session" }
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
                } else if visibleSessions.isEmpty {
                    emptyView
                } else {
                    VStack(spacing: 0) {
                        sessionList

                        if isEditing && !selectedIds.isEmpty {
                            deleteBar
                        }
                    }
                }
            }
            .navigationTitle("session history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !visibleSessions.isEmpty {
                        Button(isEditing ? "done" : "edit") {
                            withAnimation {
                                isEditing.toggle()
                                if !isEditing { selectedIds.removeAll() }
                            }
                        }
                        .foregroundColor(TarsyTheme.accentAmber)
                    }
                }
                if !isEditing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("back") { dismiss() }
                            .foregroundColor(TarsyTheme.accentAmber)
                    }
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .task {
            await client.loadSessions()
        }
        .sheet(item: $loadedSession) { session in
            SessionDetailView(session: session) { session in
                loadedSession = nil  // dismiss detail first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    continueSession(session)
                }
            }
        }
        .alert("Delete sessions?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete \(selectedIds.count)", role: .destructive) {
                Task { await deleteSessions() }
            }
        } message: {
            Text("This will permanently delete \(selectedIds.count) session\(selectedIds.count == 1 ? "" : "s") and all their messages.")
        }
        .confirmationDialog(
            "Choose workspace",
            isPresented: $showWorkspacePicker,
            titleVisibility: .visible
        ) {
            ForEach(matchedWorkspaces) { ws in
                Button(ws.name) {
                    if let session = pendingContinueSession {
                        launchInWorkspace(session: session, workspace: ws)
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingContinueSession = nil
                matchedWorkspaces = []
            }
        } message: {
            Text("Multiple workspaces match this session. Which one should continue it?")
        }
        .alert("No workspace found", isPresented: $showNoWorkspaceAlert) {
            Button("Create workspace") {
                if subscriptionManager.canCreateWorkspace(currentCount: workspaceService.workspaces.count) {
                    showNewWorkspace = true
                } else {
                    showPaywall = true
                }
            }
            Button("Cancel", role: .cancel) {
                pendingContinueSession = nil
            }
        } message: {
            let projectName = pendingContinueSession?.projectName ?? "this project"
            Text("There's no workspace configured for \(projectName) yet. Create one to continue the session.")
        }
        .sheet(isPresented: $showNewWorkspace) {
            NewWorkspaceView()
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    // MARK: - Delete bar

    private var deleteBar: some View {
        HStack {
            Button {
                if selectedIds.count == visibleSessions.count {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(visibleSessions.map(\.id))
                }
            } label: {
                Text(selectedIds.count == visibleSessions.count ? "deselect all" : "select all")
                    .font(TarsyTheme.font(size: 13, weight: .medium))
                    .foregroundColor(TarsyTheme.accentAmber)
            }

            Spacer()

            Button {
                showDeleteConfirm = true
            } label: {
                HStack(spacing: 6) {
                    if isDeleting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.white)
                    } else {
                        Image(systemName: "trash")
                            .font(TarsyTheme.font(size: 13))
                    }
                    Text("delete (\(selectedIds.count))")
                        .font(TarsyTheme.font(size: 13, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(TarsyTheme.accentTerracotta)
                .cornerRadius(8)
            }
            .disabled(isDeleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TarsyTheme.backgroundSecondary)
    }

    // MARK: - Views

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(TarsyTheme.font(size: 48))
                .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))

            Text("no sessions yet")
                .font(TarsyTheme.monoFont)
                .foregroundColor(TarsyTheme.textSecondary)

            Text("Start an AI agent on your Mac and it will appear here automatically.")
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(TarsyTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(visibleSessions) { session in
                    Button {
                        if isEditing {
                            toggleSelection(session.id)
                        } else {
                            Task { await loadDetail(session) }
                        }
                    } label: {
                        SessionCard(
                            session: session,
                            workspaceName: matchWorkspace(for: session)?.name,
                            isLoading: isLoadingDetail && selectedSession?.id == session.id,
                            isEditing: isEditing,
                            isSelected: selectedIds.contains(session.id)
                        )
                    }
                }
            }
            .padding(16)
        }
        .refreshable {
            await client.loadSessions()
        }
    }

    // MARK: - Actions

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func deleteSessions() async {
        isDeleting = true
        let ids = Array(selectedIds)
        do {
            try await client.deleteContexts(ids: ids)
            selectedIds.removeAll()
            if visibleSessions.isEmpty { isEditing = false }
        } catch {
#if DEBUG
            print("[ActiveSessions] Delete error: \(error)")
#endif
        }
        isDeleting = false
    }

    private func loadDetail(_ session: UltraContextSession) async {
        selectedSession = session
        isLoadingDetail = true
        do {
            var full = try await client.getContext(id: session.id)
            full = UltraContextSession(
                id: full.id,
                messages: full.messages,
                version: full.version,
                createdAt: session.createdAt ?? full.createdAt,
                updatedAt: full.updatedAt,
                title: session.title ?? full.title,
                hasImage: session.hasImage,
                projectPath: session.projectPath ?? full.projectPath,
                engineType: session.engineType ?? full.engineType,
                workspaceId: session.workspaceId ?? full.workspaceId,
                messageCount: full.messages.count
            )
            loadedSession = full
        } catch {
            loadedSession = session
#if DEBUG
            print("[ActiveSessions] Load detail error: \(error)")
#endif
        }
        isLoadingDetail = false
    }

    private func matchWorkspaces(for session: UltraContextSession?) -> [Workspace] {
        // Primary: match by workspaceId (reliable for monorepos)
        if let wsId = session?.workspaceId,
           let uuid = UUID(uuidString: wsId) {
            let byId = workspaceService.workspaces.filter { $0.id == uuid }
            if !byId.isEmpty { return byId }
        }

        // Fallback: match by path (for sessions created before workspaceId was added).
        // Sessions opened from monorepo workspaces are recorded against the
        // sub-project path, so check both `effectivePath` and `localPath`.
        guard let path = session?.projectPath else { return [] }
        let exact = workspaceService.workspaces.filter { $0.effectivePath == path || $0.localPath == path }
        if !exact.isEmpty { return exact }

        let prefix = workspaceService.workspaces.filter {
            path.hasPrefix($0.effectivePath) || $0.effectivePath.hasPrefix(path) ||
            path.hasPrefix($0.localPath) || $0.localPath.hasPrefix(path)
        }
        if !prefix.isEmpty { return prefix }

        let sessionDir = path.components(separatedBy: "/").last ?? ""
        guard !sessionDir.isEmpty else { return [] }
        return workspaceService.workspaces.filter {
            $0.effectivePath.components(separatedBy: "/").last == sessionDir ||
            $0.localPath.components(separatedBy: "/").last == sessionDir
        }
    }

    /// Single best match for display purposes (card subtitle)
    private func matchWorkspace(for session: UltraContextSession?) -> Workspace? {
        matchWorkspaces(for: session).first
    }

    @EnvironmentObject var subscriptionManager: SubscriptionManager

    private func continueSession(_ session: UltraContextSession) {
        let matches = matchWorkspaces(for: session)

        if matches.count > 1 {
            pendingContinueSession = session
            matchedWorkspaces = matches
            showWorkspacePicker = true
            return
        }

        if matches.count == 1 {
            launchInWorkspace(session: session, workspace: matches[0])
            return
        }

        // No workspace found for this project
        pendingContinueSession = session
        showNoWorkspaceAlert = true
    }

    private func launchInWorkspace(session: UltraContextSession, workspace: Workspace) {
        let contextSummary = session.messages
            .suffix(10)
            .map { "[\($0.role)] \($0.content)" }
            .joined(separator: "\n")

        let message = "Continue the following session. Here's the recent context:\n\n\(contextSummary)"

        connectionManager.send(WSPacket(
            action: .engineCreate,
            payload: [
                "workspacePath": workspace.effectivePath,
                "workspaceId": workspace.id.uuidString,
                "engineType": session.engineType ?? "claude",
                "message": String(message.prefix(4000))
            ]
        ))

        deepLinkRouter.pendingWorkspaceId = workspace.id
        dismiss()
    }
}

// MARK: - Session Card

private struct SessionCard: View {
    let session: UltraContextSession
    var workspaceName: String?
    var isLoading: Bool = false
    var isEditing: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(TarsyTheme.font(size: 20))
                    .foregroundColor(isSelected ? TarsyTheme.accentAmber : TarsyTheme.textSecondary.opacity(0.4))
            }

            Image(systemName: session.hasImage ? "photo" : "brain.head.profile")
                .font(TarsyTheme.font(size: 18))
                .foregroundColor(session.hasImage ? TarsyTheme.accentTerracotta : TarsyTheme.accentAmber)
                .frame(width: 36, height: 36)
                .background((session.hasImage ? TarsyTheme.accentTerracotta : TarsyTheme.accentAmber).opacity(0.15))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(TarsyTheme.font(size: 13, weight: .medium))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if workspaceName != nil || session.projectName != nil {
                        Text(workspaceName ?? session.projectName ?? "")
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.accentMoss)
                            .lineLimit(1)
                    }

                    if let count = session.messageCount, count > 0 {
                        Text("\(count) msgs")
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }

                    if let created = session.createdAt {
                        Text(formatDate(created))
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }
            }

            Spacer()

            if !isEditing {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(TarsyTheme.accentAmber)
                } else {
                    Image(systemName: "chevron.right")
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))
                }
            }
        }
        .padding(12)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? TarsyTheme.accentAmber : TarsyTheme.backgroundTertiary, lineWidth: isSelected ? 1.5 : 1)
        )
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

// MARK: - Session Detail

private struct SessionDetailView: View {
    @Environment(\.dismiss) var dismiss
    let session: UltraContextSession
    var onContinue: ((UltraContextSession) -> Void)?

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    if session.messages.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(TarsyTheme.font(size: 36))
                                .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))
                            Text("no messages yet")
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(session.messages.enumerated()), id: \.offset) { _, message in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: message.role == "user" ? "person.fill" : "brain")
                                            .font(TarsyTheme.font(size: 10))
                                            .foregroundColor(message.role == "user" ? TarsyTheme.accentAmber : TarsyTheme.accentMoss)
                                            .frame(width: 20)
                                            .padding(.top, 2)

                                        Text(message.content)
                                            .font(TarsyTheme.font(size: 12))
                                            .foregroundColor(TarsyTheme.textPrimary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(10)
                                    .background(message.role == "user" ? TarsyTheme.backgroundSecondary : TarsyTheme.backgroundTertiary.opacity(0.5))
                                    .cornerRadius(8)
                                }
                            }
                            .padding(12)
                        }
                    }

                    if let onContinue, !session.messages.isEmpty {
                        Button {
                            onContinue(session)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("continue session")
                            }
                            .font(TarsyTheme.font(size: 14, weight: .medium))
                            .foregroundColor(TarsyTheme.backgroundPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(TarsyTheme.accentAmber)
                            .cornerRadius(10)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }
            }
            .navigationTitle(session.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") { dismiss() }
                        .foregroundColor(TarsyTheme.accentAmber)
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

#if DEBUG
#Preview {
    PreviewWrapper {
        ActiveSessionsView()
    }
}
#endif
