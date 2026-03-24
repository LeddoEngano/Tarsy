import SwiftUI
import TarsyShared

struct GitSafetyNetView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab = 0 // 0=changes, 1=history
    @State private var changedFiles: [GitFileChange] = []
    @State private var diffText = ""
    @State private var commits: [GitCommit] = []
    @State private var isLoading = true
    @State private var showRollbackConfirm = false
    @State private var rollbackTarget: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab selector
                HStack(spacing: 0) {
                    tabButton("Changes", index: 0)
                    tabButton("History", index: 1)
                }
                .background(TarsyTheme.backgroundSecondary)

                if isLoading {
                    Spacer()
                    ProgressView()
                        .tint(TarsyTheme.accentAmber)
                    Spacer()
                } else if selectedTab == 0 {
                    changesView
                } else {
                    historyView
                }
            }
            .background(TarsyTheme.backgroundPrimary)
            .navigationTitle("git safety net")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("close") { dismiss() }
                        .foregroundColor(TarsyTheme.accentAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { createCheckpoint() }) {
                        Label("checkpoint", systemImage: "shield.checkered")
                    }
                    .foregroundColor(TarsyTheme.accentMoss)
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            loadData()
            setupListeners()
        }
        .onDisappear {
            connectionManager.removeListener("git-safety-\(workspace.id)")
        }
        .confirmationDialog(
            "Rollback to this checkpoint?",
            isPresented: $showRollbackConfirm,
            titleVisibility: .visible
        ) {
            Button("Rollback", role: .destructive) {
                if let target = rollbackTarget {
                    performRollback(to: target)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will discard all changes since this checkpoint. This cannot be undone.")
        }
    }

    // MARK: - Changes View

    private var changesView: some View {
        ScrollView {
            if changedFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundColor(TarsyTheme.accentMoss)
                    Text("No changes")
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(changedFiles) { file in
                        HStack(spacing: 8) {
                            Text(file.status)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(file.statusColor)
                                .frame(width: 20)

                            Text(file.path)
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(TarsyTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(TarsyTheme.backgroundSecondary)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - History View

    private var historyView: some View {
        ScrollView {
            if commits.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundColor(TarsyTheme.textSecondary)
                    Text("No commits")
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(commits) { commit in
                        Button(action: {
                            rollbackTarget = commit.hash
                            showRollbackConfirm = true
                        }) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(commit.shortHash)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(TarsyTheme.accentAmber)

                                    if commit.message.contains("checkpoint:") {
                                        Image(systemName: "shield.checkered")
                                            .font(.system(size: 10))
                                            .foregroundColor(TarsyTheme.accentMoss)
                                    }

                                    Spacer()

                                    Text(commit.relativeDate)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(TarsyTheme.textSecondary)
                                }

                                Text(commit.message)
                                    .font(TarsyTheme.monoFontSmall)
                                    .foregroundColor(TarsyTheme.textPrimary)
                                    .lineLimit(2)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(TarsyTheme.backgroundSecondary)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Tab Button

    private func tabButton(_ title: String, index: Int) -> some View {
        Button(action: { selectedTab = index }) {
            Text(title)
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(selectedTab == index ? TarsyTheme.accentAmber : TarsyTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selectedTab == index ? TarsyTheme.backgroundTertiary : Color.clear)
        }
    }

    // MARK: - Actions

    private func loadData() {
        connectionManager.send(WSPacket(action: .gitDiff, payload: ["path": workspace.localPath]))
        connectionManager.send(WSPacket(action: .gitHistory, payload: ["path": workspace.localPath, "limit": "30"]))
    }

    private func setupListeners() {
        connectionManager.addListener("git-safety-\(workspace.id)") { [self] packet in
            Task { @MainActor in
                switch packet.action {
                case .gitDiffResult:
                    isLoading = false
                    if let status = packet.payload?["status"] {
                        changedFiles = parseGitStatus(status)
                    }
                    diffText = packet.payload?["diff"] ?? ""

                case .gitHistoryResult:
                    isLoading = false
                    if let json = packet.payload?["commits"],
                       let data = json.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                        commits = parsed.map { GitCommit(from: $0) }
                    }

                case .gitCheckpointResult:
                    // Reload data after checkpoint
                    loadData()

                case .gitRollbackResult:
                    if packet.payload?["success"] == "true" {
                        Haptics.success()
                        loadData()
                    } else {
                        Haptics.error()
                    }

                default:
                    break
                }
            }
        }
    }

    private func createCheckpoint() {
        Haptics.medium()
        connectionManager.send(WSPacket(
            action: .gitCheckpoint,
            payload: ["path": workspace.localPath, "message": "manual checkpoint"]
        ))
    }

    private func performRollback(to hash: String) {
        connectionManager.send(WSPacket(
            action: .gitRollback,
            payload: ["path": workspace.localPath, "target": hash]
        ))
    }

    // MARK: - Parsing

    private func parseGitStatus(_ status: String) -> [GitFileChange] {
        status.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in
                let statusChar = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
                let path = String(line.dropFirst(3))
                return GitFileChange(status: statusChar, path: path)
            }
    }
}

// MARK: - Models

struct GitFileChange: Identifiable {
    let id = UUID()
    let status: String
    let path: String

    var statusColor: Color {
        switch status {
        case "M": return TarsyTheme.accentAmber
        case "A", "?": return TarsyTheme.accentMoss
        case "D": return TarsyTheme.accentTerracotta
        default: return TarsyTheme.textSecondary
        }
    }
}

struct GitCommit: Identifiable {
    let id = UUID()
    let hash: String
    let message: String
    let date: String
    let author: String

    var shortHash: String { String(hash.prefix(7)) }

    var relativeDate: String {
        // Simple relative date from ISO string
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withSpaceBetweenDateAndTime]
        guard let commitDate = formatter.date(from: date) else { return date }
        let interval = Date().timeIntervalSince(commitDate)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    init(from dict: [String: String]) {
        self.hash = dict["hash"] ?? ""
        self.message = dict["message"] ?? ""
        self.date = dict["date"] ?? ""
        self.author = dict["author"] ?? ""
    }
}
