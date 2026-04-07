import SwiftUI
import TarsyShared

struct GitSafetyNetView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab = 0 // 0=changes, 1=history, 2=branches
    @State private var changedFiles: [GitFileChange] = []
    @State private var commits: [GitCommit] = []
    @State private var branches: [String] = []
    @State private var currentBranch = ""
    @State private var isLoading = true
    @State private var showRollbackConfirm = false
    @State private var rollbackTarget: String?
    @State private var selectedFileDiff: FileDiffData?
    @State private var showDiscardConfirm = false
    @State private var discardTarget: String? // nil = discard all

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tabButton("Changes", index: 0)
                    tabButton("History", index: 1)
                    tabButton("Branches", index: 2)
                }
                .background(TarsyTheme.backgroundSecondary)

                if isLoading {
                    Spacer()
                    ProgressView().tint(TarsyTheme.accentAmber)
                    Spacer()
                } else {
                    switch selectedTab {
                    case 0: changesView
                    case 1: historyView
                    case 2: branchesView
                    default: EmptyView()
                    }
                }
            }
            .background(TarsyTheme.backgroundPrimary)
            .navigationTitle("git")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("close") { dismiss() }
                        .foregroundColor(TarsyTheme.accentAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { createCheckpoint() }) {
                        ZStack(alignment: .bottomTrailing) {
                            Image("GitCommitIcon")
                                .renderingMode(.original)
                                .resizable()
                                .frame(width: 26, height: 26)
                            Image(systemName: "plus")
                                .font(TarsyTheme.font(size: 10, weight: .bold))
                                .foregroundColor(Color(red: 0.133, green: 0.773, blue: 0.369))
                                .offset(x: -12, y: -1)
                        }
                    }
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { loadData(); setupListeners() }
        .onDisappear { connectionManager.removeListener("git-\(workspace.id)") }
        .confirmationDialog("Rollback to this checkpoint?", isPresented: $showRollbackConfirm, titleVisibility: .visible) {
            Button("Rollback", role: .destructive) {
                if let target = rollbackTarget { performRollback(to: target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will discard all changes since this checkpoint. This cannot be undone.")
        }
        .confirmationDialog(
            "Discard changes to \(discardTarget ?? "all unstaged files")?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Discard", role: .destructive) {
                if let file = discardTarget {
                    discardFile(file)
                } else {
                    discardAll()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .sheet(item: $selectedFileDiff) { diff in
            FileDiffView(diff: diff)
        }
    }

    // MARK: - Changes View

    private var stagedFiles: [GitFileChange] {
        changedFiles.filter { $0.isStaged }
    }

    private var unstagedFiles: [GitFileChange] {
        changedFiles.filter { !$0.isStaged }
    }

    private var changesView: some View {
        ScrollView {
            if changedFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(TarsyTheme.font(size: 40))
                        .foregroundColor(TarsyTheme.accentMoss)
                    Text("No changes")
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                .padding(.top, 60)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // MARK: Staged Changes
                    if !stagedFiles.isEmpty {
                        changesSectionHeader(
                            title: "Staged Changes",
                            count: stagedFiles.count,
                            actions: [
                                ("minus", "Unstage All", { unstageAll() }),
                            ]
                        )
                        ForEach(stagedFiles) { file in
                            changeFileRow(file: file)
                        }
                    }

                    // MARK: Changes (unstaged)
                    if !unstagedFiles.isEmpty {
                        changesSectionHeader(
                            title: "Changes",
                            count: unstagedFiles.count,
                            actions: [
                                ("plus", "Stage All", { stageAll() }),
                                ("arrow.uturn.backward", "Discard All", {
                                    discardTarget = nil
                                    showDiscardConfirm = true
                                }),
                            ]
                        )
                        ForEach(unstagedFiles) { file in
                            changeFileRow(file: file)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func changesSectionHeader(title: String, count: Int, actions: [(icon: String, label: String, action: () -> Void)]) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(TarsyTheme.font(size: 11, weight: .semibold))
                .foregroundColor(TarsyTheme.textSecondary)
                .textCase(.uppercase)

            Text("\(count)")
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(TarsyTheme.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(TarsyTheme.backgroundTertiary)
                .cornerRadius(4)

            Spacer()

            ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                Button(action: item.action) {
                    Image(systemName: item.icon)
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.top, 4)
    }

    private func changeFileRow(file: GitFileChange) -> some View {
        Button(action: { requestFileDiff(file.path) }) {
            HStack(spacing: 8) {
                Text(file.statusLabel)
                    .font(TarsyTheme.font(size: 11, weight: .medium))
                    .foregroundColor(file.statusColor)
                    .frame(width: 18)

                Text(file.path)
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Inline action buttons
                if file.isStaged {
                    Button(action: { unstageFile(file.path) }) {
                        Image(systemName: "minus")
                            .font(TarsyTheme.font(size: 11))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(width: 24, height: 24)
                    }
                } else {
                    Button(action: {
                        discardTarget = file.path
                        showDiscardConfirm = true
                    }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(TarsyTheme.font(size: 11))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(width: 24, height: 24)
                    }
                    Button(action: { stageFile(file.path) }) {
                        Image(systemName: "plus")
                            .font(TarsyTheme.font(size: 11))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(width: 24, height: 24)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(TarsyTheme.backgroundSecondary)
        }
    }

    // MARK: - History View

    private var historyView: some View {
        ScrollView {
            if commits.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock")
                        .font(TarsyTheme.font(size: 40))
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
                                        .font(TarsyTheme.font(size: 11))
                                        .foregroundColor(TarsyTheme.accentAmber)

                                    if commit.message.contains("checkpoint:") {
                                        Image(systemName: "arrow.triangle.branch")
                                            .font(TarsyTheme.font(size: 10))
                                            .foregroundColor(TarsyTheme.accentMoss)
                                    }

                                    Spacer()

                                    Text(commit.relativeDate)
                                        .font(TarsyTheme.font(size: 10))
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

    // MARK: - Branches View

    private var branchesView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(branches, id: \.self) { branch in
                    Button(action: { checkout(branch) }) {
                        HStack(spacing: 10) {
                            Image(systemName: branch == currentBranch ? "checkmark.circle.fill" : "circle")
                                .font(TarsyTheme.font(size: 14))
                                .foregroundColor(branch == currentBranch ? TarsyTheme.accentMoss : TarsyTheme.textSecondary)

                            Text(branch)
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(branch == currentBranch ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)

                            Spacer()

                            if branch == currentBranch {
                                Text("current")
                                    .font(TarsyTheme.font(size: 9))
                                    .foregroundColor(TarsyTheme.accentMoss)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(TarsyTheme.accentMoss.opacity(0.15))
                                    .cornerRadius(4)
                            }
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

    // MARK: - Shared

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
        connectionManager.send(WSPacket(action: .gitBranches, payload: ["path": workspace.localPath]))
    }

    private func setupListeners() {
        connectionManager.addListener("git-\(workspace.id)") { [self] packet in
            Task { @MainActor in
                switch packet.action {
                case .gitDiffResult:
                    isLoading = false
                    if let status = packet.payload?["status"] {
                        changedFiles = parseGitStatus(status)
                    }
                case .gitHistoryResult:
                    isLoading = false
                    if let json = packet.payload?["commits"],
                       let data = json.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                        commits = parsed.map { GitCommit(from: $0) }
                    }
                case .gitBranchesResult:
                    currentBranch = packet.payload?["current"] ?? ""
                    if let json = packet.payload?["branches"],
                       let data = json.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] {
                        branches = parsed
                    }
                case .gitCheckpointResult, .gitCheckoutResult, .gitPullResult, .gitStageResult, .gitDiscardResult:
                    Haptics.medium()
                    loadData()
                case .gitRollbackResult:
                    if packet.payload?["success"] == "true" {
                        Haptics.success()
                        loadData()
                    } else {
                        Haptics.error()
                    }
                case .gitFileDiffResult:
                    if let file = packet.payload?["file"],
                       let diff = packet.payload?["diff"] {
                        selectedFileDiff = FileDiffData(file: file, diff: diff)
                    }
                default: break
                }
            }
        }
    }

    private func createCheckpoint() {
        Haptics.medium()
        connectionManager.send(WSPacket(action: .gitCheckpoint, payload: ["path": workspace.localPath, "message": "manual checkpoint"]))
    }

    private func performRollback(to hash: String) {
        connectionManager.send(WSPacket(action: .gitRollback, payload: ["path": workspace.localPath, "target": hash]))
    }

    private func requestFileDiff(_ file: String) {
        connectionManager.send(WSPacket(action: .gitFileDiff, payload: ["path": workspace.localPath, "file": file]))
    }

    private func checkout(_ branch: String) {
        guard branch != currentBranch else { return }
        connectionManager.send(WSPacket(action: .gitCheckout, payload: ["path": workspace.localPath, "branch": branch]))
    }

    // MARK: - Stage / Discard

    private func stageFile(_ file: String) {
        Haptics.light()
        connectionManager.send(WSPacket(action: .gitStage, payload: ["path": workspace.localPath, "files": file]))
    }

    private func stageAll() {
        Haptics.light()
        connectionManager.send(WSPacket(action: .gitStage, payload: ["path": workspace.localPath]))
    }

    private func unstageFile(_ file: String) {
        Haptics.light()
        connectionManager.send(WSPacket(action: .gitDiscard, payload: ["path": workspace.localPath, "files": file, "staged": "true"]))
    }

    private func unstageAll() {
        Haptics.light()
        connectionManager.send(WSPacket(action: .gitDiscard, payload: ["path": workspace.localPath, "staged": "true"]))
    }

    private func discardFile(_ file: String) {
        Haptics.medium()
        connectionManager.send(WSPacket(action: .gitDiscard, payload: ["path": workspace.localPath, "files": file]))
    }

    private func discardAll() {
        Haptics.medium()
        connectionManager.send(WSPacket(action: .gitDiscard, payload: ["path": workspace.localPath, "includeUntracked": "true"]))
    }

    private func parseGitStatus(_ status: String) -> [GitFileChange] {
        // git status --porcelain format: XY path
        // X = index (staged), Y = working tree (unstaged)
        // " " = unmodified, "?" = untracked
        var files: [GitFileChange] = []
        for line in status.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard line.count >= 3 else { continue }
            let x = line[line.startIndex] // staged status
            let y = line[line.index(after: line.startIndex)] // unstaged status
            let path = String(line.dropFirst(3))

            // Staged change (X is not " " and not "?")
            if x != " " && x != "?" {
                files.append(GitFileChange(status: String(x), path: path, isStaged: true))
            }
            // Unstaged change (Y is not " ") or untracked (??)
            if y != " " || x == "?" {
                let s = x == "?" ? "?" : String(y)
                files.append(GitFileChange(status: s, path: path, isStaged: false))
            }
        }
        return files
    }
}

// MARK: - Diff Viewer

struct FileDiffData: Identifiable {
    let id = UUID()
    let file: String
    let diff: String
}

struct FileDiffView: View {
    let diff: FileDiffData
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(parseHunks().enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 0) {
                            Text(line.lineNum)
                                .font(TarsyTheme.font(size: 10))
                                .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                                .frame(width: 36, alignment: .trailing)
                                .padding(.trailing, 6)

                            Text(line.content)
                                .font(TarsyTheme.font(size: 12))
                                .foregroundColor(line.textColor)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.bgColor)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(TarsyTheme.backgroundPrimary)
            .navigationTitle(diff.file)
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

    private func parseHunks() -> [DiffLine] {
        var lines: [DiffLine] = []
        var lineNum = 0

        for rawLine in diff.diff.components(separatedBy: "\n") {
            if rawLine.hasPrefix("@@") {
                // Hunk header — extract line number
                if let range = rawLine.range(of: #"\+(\d+)"#, options: .regularExpression) {
                    lineNum = Int(rawLine[range].dropFirst()) ?? 0
                }
                lines.append(DiffLine(content: rawLine, type: .hunkHeader, lineNum: ""))
                continue
            }
            if rawLine.hasPrefix("---") || rawLine.hasPrefix("+++") || rawLine.hasPrefix("diff ") || rawLine.hasPrefix("index ") {
                continue // Skip diff metadata
            }
            if rawLine.hasPrefix("+") {
                lines.append(DiffLine(content: String(rawLine.dropFirst()), type: .added, lineNum: "\(lineNum)"))
                lineNum += 1
            } else if rawLine.hasPrefix("-") {
                lines.append(DiffLine(content: String(rawLine.dropFirst()), type: .removed, lineNum: ""))
            } else {
                lines.append(DiffLine(content: rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine, type: .context, lineNum: "\(lineNum)"))
                lineNum += 1
            }
        }
        return lines
    }
}

struct DiffLine {
    let content: String
    let type: DiffLineType
    let lineNum: String

    enum DiffLineType { case added, removed, context, hunkHeader }

    var textColor: Color {
        switch type {
        case .added: return Color(red: 0.5, green: 0.9, blue: 0.5)
        case .removed: return Color(red: 0.9, green: 0.5, blue: 0.5)
        case .hunkHeader: return TarsyTheme.accentAmber
        case .context: return TarsyTheme.textPrimary
        }
    }

    var bgColor: Color {
        switch type {
        case .added: return Color(red: 0.2, green: 0.35, blue: 0.2)
        case .removed: return Color(red: 0.35, green: 0.2, blue: 0.2)
        case .hunkHeader: return TarsyTheme.backgroundSecondary
        case .context: return .clear
        }
    }
}

// MARK: - Models

struct GitFileChange: Identifiable {
    let id = UUID()
    let status: String
    let path: String
    let isStaged: Bool

    var statusColor: Color {
        switch status {
        case "M": return TarsyTheme.accentAmber
        case "A", "?": return TarsyTheme.accentMoss
        case "D": return TarsyTheme.accentTerracotta
        case "R": return Color(red: 0.6, green: 0.6, blue: 0.9)
        default: return TarsyTheme.textSecondary
        }
    }

    var statusLabel: String {
        switch status {
        case "M": return "M"
        case "A": return "A"
        case "?": return "U"
        case "D": return "D"
        case "R": return "R"
        default: return status
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

#if DEBUG
#Preview {
    GitSafetyNetView(workspace: PreviewData.workspace)
        .environmentObject(ConnectionManager())
        .preferredColorScheme(.dark)
}
#endif
