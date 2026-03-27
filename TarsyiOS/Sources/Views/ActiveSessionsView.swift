import SwiftUI
import TarsyShared

struct ActiveSessionsView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var client = UltraContextClient.configured()
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var workspaceService: WorkspaceService
    @State private var selectedSession: UltraContextSession?
    @State private var loadedSession: UltraContextSession?
    @State private var showContinueConfirm = false
    @State private var sessionToContinue: UltraContextSession?
    @State private var isLoadingDetail = false

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
                } else if client.sessions.isEmpty {
                    emptyView
                } else {
                    sessionList
                }
            }
            .navigationTitle("active sessions")
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
        .preferredColorScheme(.dark)
        .task {
            await client.loadSessions()
        }
        .sheet(item: $loadedSession) { session in
            SessionDetailView(session: session) { sessionToContinue in
                self.sessionToContinue = sessionToContinue
                showContinueConfirm = true
            }
        }
        .alert("Continue this session?", isPresented: $showContinueConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                if let session = sessionToContinue,
                   let workspace = workspaceService.workspaces.first {
                    continueSession(session, in: workspace)
                }
            }
        } message: {
            Text("This will start a new agent tab with context from this session.")
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))

            Text("no active sessions")
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
                ForEach(client.sessions) { session in
                    Button {
                        Task { await loadDetail(session) }
                    } label: {
                        SessionCard(session: session, isLoading: isLoadingDetail && selectedSession?.id == session.id)
                    }
                }
            }
            .padding(16)
        }
        .refreshable {
            await client.loadSessions()
        }
    }

    private func loadDetail(_ session: UltraContextSession) async {
        selectedSession = session
        isLoadingDetail = true
        do {
            let full = try await client.getContext(id: session.id)
            loadedSession = full
        } catch {
            // Fallback to session without messages
            loadedSession = session
            print("[ActiveSessions] Load detail error: \(error)")
        }
        isLoadingDetail = false
    }

    private func continueSession(_ session: UltraContextSession, in workspace: Workspace) {
        let contextSummary = session.messages
            .suffix(10)
            .map { "[\($0.role)] \($0.content)" }
            .joined(separator: "\n")

        let message = "Continue the following session. Here's the recent context:\n\n\(contextSummary)"

        connectionManager.send(WSPacket(
            action: .engineCreate,
            payload: [
                "workspacePath": workspace.localPath ?? "",
                "workspaceId": workspace.id.uuidString,
                "engineType": "claude",
                "message": String(message.prefix(4000))
            ]
        ))

        dismiss()
    }
}

// MARK: - Session Card

private struct SessionCard: View {
    let session: UltraContextSession
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18))
                .foregroundColor(TarsyTheme.accentAmber)
                .frame(width: 36, height: 36)
                .background(TarsyTheme.accentAmber.opacity(0.15))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text("Session \(session.id.prefix(8))")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)

                HStack(spacing: 8) {
                    if let created = session.createdAt {
                        Text(formatDate(created))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }

                    if session.messages.count > 0 {
                        Text("\(session.messages.count) messages")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(TarsyTheme.accentMoss)
                    }
                }

                if let last = session.messages.last {
                    Text(last.content.prefix(80).description + (last.content.count > 80 ? "..." : ""))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.7))
                        .lineLimit(2)
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(TarsyTheme.accentAmber)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))
            }
        }
        .padding(12)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
        )
    }

    private func formatDate(_ dateStr: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: dateStr) else {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: dateStr) else { return dateStr.prefix(10).description }
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
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
                                .font(.system(size: 36))
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
                                            .font(.system(size: 10))
                                            .foregroundColor(message.role == "user" ? TarsyTheme.accentAmber : TarsyTheme.accentMoss)
                                            .frame(width: 20)
                                            .padding(.top, 2)

                                        Text(message.content)
                                            .font(.system(size: 12, design: .monospaced))
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
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
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
            .navigationTitle("Session \(session.id.prefix(8))")
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
        .preferredColorScheme(.dark)
    }
}
