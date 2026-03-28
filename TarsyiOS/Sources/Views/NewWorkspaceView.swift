import SwiftUI
import TarsyShared

struct ScannedRepo: Codable {
    let name: String
    let path: String
    let remoteUrl: String?
    let currentBranch: String?
    let stack: String?
}

struct NewWorkspaceView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    @State private var showPaywall = false

    @State private var name = ""
    @State private var repoUrl = ""
    @State private var localPath = ""
    @State private var stack: Workspace.WorkspaceStack = .web
    @State private var workspaceType: Workspace.WorkspaceType = .standard
    @State private var devServerCommand = ""
    @State private var isCreating = false
    @State private var error: String?

    // Repo scanning
    @State private var scannedRepos: [ScannedRepo] = []
    @State private var isScanning = false
    @State private var showRepoList = true
    @State private var searchText = ""
    @State private var isAnalyzing = false
    @State private var detectedLanguage: String?
    @State private var detectedFramework: String?

    private var filteredRepos: [ScannedRepo] {
        if searchText.isEmpty { return scannedRepos }
        return scannedRepos.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            ($0.remoteUrl ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Scanned repos from Mac
                        if showRepoList {
                            repoSuggestions
                        }

                        // Manual form (shown after selecting or toggling)
                        if !showRepoList || !name.isEmpty {
                            manualForm
                        }
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("new workspace")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.accentAmber)
                    Spacer()
                    Button("cancel") { dismiss() }
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(TarsyTheme.backgroundPrimary)
            }
        }
        .onAppear { scanRepos() }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptionManager)
        }
    }

    // MARK: - Repo Suggestions

    private var repoSuggestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("repos on your mac")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
                Spacer()
                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(TarsyTheme.accentAmber)
                } else {
                    Button(action: { scanRepos() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }
            }

            if !scannedRepos.isEmpty {
                // Search
                TextField("", text: $searchText, prompt: Text("search repos...").foregroundColor(TarsyTheme.textSecondary.opacity(0.5)))
                    .textFieldStyle(.plain)
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textPrimary)
                    .padding(10)
                    .background(TarsyTheme.backgroundSecondary)
                    .cornerRadius(8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                // Repo list
                LazyVStack(spacing: 8) {
                    ForEach(filteredRepos, id: \.path) { repo in
                        Button(action: { selectRepo(repo) }) {
                            repoCard(repo)
                        }
                    }
                }
            } else if !isScanning {
                Text("no repos found. connect your mac first.")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
                    .padding(12)
            }

            // Toggle to manual
            Button(action: {
                withAnimation { showRepoList = false }
            }) {
                HStack {
                    Image(systemName: "plus.circle")
                        .font(.caption)
                    Text("create from scratch")
                        .font(TarsyTheme.monoFontSmall)
                }
                .foregroundColor(TarsyTheme.accentAmber)
            }
        }
    }

    @ViewBuilder
    private func repoCard(_ repo: ScannedRepo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundColor(TarsyTheme.accentAmber)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(TarsyTheme.monoFont)
                    .foregroundColor(TarsyTheme.textPrimary)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    if let branch = repo.currentBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                    if let s = repo.stack {
                        Text(s)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(TarsyTheme.accentAmber)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(TarsyTheme.accentAmber.opacity(0.15))
                            .cornerRadius(3)
                    }
                }

                Text(repo.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.6))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))
        }
        .padding(12)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
        )
    }

    // MARK: - Manual Form

    private var manualForm: some View {
        VStack(spacing: 16) {
            if showRepoList {
                // Show back button if we came from repo selection
                HStack {
                    Button(action: {
                        withAnimation {
                            name = ""
                            showRepoList = true
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.caption)
                            Text("back to repos")
                                .font(TarsyTheme.monoFontSmall)
                        }
                        .foregroundColor(TarsyTheme.textSecondary)
                    }
                    Spacer()
                }
            }

            fieldSection("project name") {
                tarsyTextField("EDONext", text: $name)
            }

            fieldSection("repository url (optional)") {
                tarsyTextField("https://github.com/user/repo.git", text: $repoUrl)
                    .keyboardType(.URL)
            }

            fieldSection("local path on mac") {
                tarsyTextField("~/Projects/my-app", text: $localPath)
            }

            fieldSection("stack") {
                HStack(spacing: 8) {
                    ForEach([Workspace.WorkspaceStack.web, .mobile, .backend, .fullstack], id: \.rawValue) { s in
                        stackChip(s)
                    }
                }
            }

            fieldSection("workspace type") {
                HStack(spacing: 8) {
                    Button(action: { workspaceType = .standard }) {
                        HStack(spacing: 4) {
                            Image(systemName: "macwindow")
                                .font(.system(size: 10))
                            Text("standard")
                                .font(TarsyTheme.monoFontSmall)
                        }
                        .foregroundColor(workspaceType == .standard ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(workspaceType == .standard ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
                        .cornerRadius(8)
                    }
                    Button(action: {
                        if subscriptionManager.isPro {
                            workspaceType = .openClaw
                        } else {
                            showPaywall = true
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "display")
                                .font(.system(size: 10))
                            Text("openclaw")
                                .font(TarsyTheme.monoFontSmall)
                            if !subscriptionManager.isPro {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                            }
                        }
                        .foregroundColor(workspaceType == .openClaw ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(workspaceType == .openClaw ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
                        .cornerRadius(8)
                    }
                }

                if workspaceType == .openClaw {
                    Text("streams the full desktop instead of a single window. designed for watching OpenClaw work.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }

            fieldSection("dev server command (optional)") {
                VStack(alignment: .leading, spacing: 4) {
                    tarsyTextField("npm run dev", text: $devServerCommand)
                    if isAnalyzing {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini).tint(TarsyTheme.accentAmber)
                            Text("analyzing repo...")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                    } else if !devServerCommand.isEmpty && (detectedLanguage != nil || detectedFramework != nil) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundColor(TarsyTheme.accentMoss)
                            Text("auto-detected")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(TarsyTheme.accentMoss)
                            if let lang = detectedLanguage {
                                Text(lang)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(TarsyTheme.accentAmber)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(TarsyTheme.accentAmber.opacity(0.15))
                                    .cornerRadius(3)
                            }
                            if let fw = detectedFramework {
                                Text(fw)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(TarsyTheme.accentAmber)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(TarsyTheme.accentAmber.opacity(0.15))
                                    .cornerRadius(3)
                            }
                        }
                    }
                }
            }

            if let error {
                Text(error)
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.accentTerracotta)
            }

            Button(action: { Task { await createWorkspace() } }) {
                HStack {
                    if isCreating {
                        ProgressView()
                            .tint(TarsyTheme.backgroundPrimary)
                            .scaleEffect(0.8)
                    }
                    Text(isCreating ? "creating..." : "create workspace")
                        .font(TarsyTheme.monoFont)
                }
                .foregroundColor(TarsyTheme.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(name.isEmpty ? TarsyTheme.textSecondary : TarsyTheme.accentAmber)
                .cornerRadius(12)
            }
            .disabled(name.isEmpty || isCreating)
        }
    }

    // MARK: - Actions

    private func scanRepos() {
        isScanning = true
        connectionManager.send(WSPacket(action: .workspaceScanRepos))

        connectionManager.addListener("scan_repos") { packet in
            guard packet.action == .workspaceScanResult,
                  let json = packet.payload?["repos"],
                  let data = json.data(using: .utf8) else { return }

            Task { @MainActor in
                self.connectionManager.removeListener("scan_repos")
                if let repos = try? JSONDecoder().decode([ScannedRepo].self, from: data) {
                    self.scannedRepos = repos
                } else {
                    self.error = "failed to parse repo list from mac"
                }
                self.isScanning = false
            }
        }

        // Timeout
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if isScanning {
                    isScanning = false
                    connectionManager.removeListener("scan_repos")
                }
            }
        }
    }

    private func selectRepo(_ repo: ScannedRepo) {
        name = repo.name
        localPath = repo.path
        repoUrl = repo.remoteUrl ?? ""
        if let s = repo.stack, let ws = Workspace.WorkspaceStack(rawValue: s) {
            stack = ws
        }
        withAnimation { showRepoList = false }
        analyzeRepo(path: repo.path)
    }

    private func analyzeRepo(path: String) {
        isAnalyzing = true
        connectionManager.send(WSPacket(action: .repoAnalyze, payload: ["path": path]))

        connectionManager.addListener("repo_analysis") { packet in
            guard packet.action == .repoAnalysis,
                  let json = packet.payload?["analysis"],
                  let data = json.data(using: .utf8) else { return }

            Task { @MainActor in
                self.connectionManager.removeListener("repo_analysis")
                self.isAnalyzing = false

                struct Analysis: Codable {
                    let language: String?
                    let framework: String?
                    let stack: String?
                    let suggestedCommand: String?
                }

                guard let analysis = try? JSONDecoder().decode(Analysis.self, from: data) else {
                    self.error = "failed to analyze repo"
                    return
                }

                // Auto-fill dev server command if empty
                if self.devServerCommand.isEmpty, let cmd = analysis.suggestedCommand {
                    self.devServerCommand = cmd
                }

                // Update stack if detected
                if let s = analysis.stack, let ws = Workspace.WorkspaceStack(rawValue: s) {
                    self.stack = ws
                }

                self.detectedLanguage = analysis.language
                self.detectedFramework = analysis.framework
            }
        }

        // Timeout
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                if isAnalyzing {
                    isAnalyzing = false
                    connectionManager.removeListener("repo_analysis")
                }
            }
        }
    }

    private func createWorkspace() async {
        guard let machineId = machineService.machine?.id else {
            error = "no mac connected. open tarsy on your mac first."
            return
        }

        isCreating = true
        error = nil

        do {
            let session = try await supabase.auth.session
            let request = CreateWorkspaceRequest(
                userId: session.user.id.uuidString,
                machineId: machineId.uuidString,
                name: name,
                repoUrl: repoUrl.isEmpty ? nil : repoUrl,
                localPath: localPath.isEmpty ? "~/Projects/\(name.lowercased())" : localPath,
                stack: stack.rawValue,
                workspaceType: workspaceType.rawValue,
                devServerCommand: devServerCommand.isEmpty ? nil : devServerCommand,
                streamUrl: nil,
                aiContext: nil
            )
            let _ = try await workspaceService.createWorkspace(request)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }

    // MARK: - Helpers

    @ViewBuilder
    private func fieldSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(TarsyTheme.textSecondary)
            content()
        }
    }

    @ViewBuilder
    private func tarsyTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(TarsyTheme.textSecondary.opacity(0.5)))
            .textFieldStyle(.plain)
            .font(TarsyTheme.monoFont)
            .foregroundColor(TarsyTheme.textPrimary)
            .padding(14)
            .background(TarsyTheme.backgroundSecondary)
            .cornerRadius(10)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }

    @ViewBuilder
    private func stackChip(_ s: Workspace.WorkspaceStack) -> some View {
        Button(action: { stack = s }) {
            Text(s.rawValue)
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(stack == s ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(stack == s ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
                .cornerRadius(8)
        }
    }
}
