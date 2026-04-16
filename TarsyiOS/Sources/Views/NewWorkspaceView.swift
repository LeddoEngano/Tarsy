import SwiftUI
import TarsyShared

struct ScannedRepo: Codable {
    let name: String
    let path: String
    let remoteUrl: String?
    let currentBranch: String?
    let stack: String?
}

struct DetectedSubProject: Codable, Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let stack: String?
    let framework: String?
    let language: String?
    let suggestedCommand: String?
}

struct NewWorkspaceView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var name = ""
    @State private var repoUrl = ""
    @State private var localPath = ""
    // `stack` is still tracked because it's sent to the backend and drives
    // streaming / icon behavior, but the user no longer picks it manually —
    // it's auto-detected by RepoAnalyzer or set via the monorepo sub-project
    // picker below.
    @State private var stack: Workspace.WorkspaceStack = .web
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

    // Monorepo support: if the analyzed repo contains multiple sub-projects,
    // show a picker so the user can scope the dev server command to the
    // project they actually want to run.
    @State private var detectedProjects: [DetectedSubProject] = []
    @State private var selectedProjectPath: String? = nil

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
                        .font(TarsyTheme.font(size: 20, weight: .bold))
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
                VStack(spacing: 8) {
                    Text(error != nil ? (error ?? "") : "no repos found. connect your mac first.")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(12)

                    if error != nil {
                        Button(action: { scanRepos() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption)
                                Text("retry")
                                    .font(TarsyTheme.monoFontSmall)
                            }
                            .foregroundColor(TarsyTheme.accentAmber)
                        }
                    }
                }
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
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                    if let s = repo.stack {
                        Text(s)
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.accentAmber)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(TarsyTheme.accentAmber.opacity(0.15))
                            .cornerRadius(3)
                    }
                }

                Text(repo.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(TarsyTheme.font(size: 9))
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

            if !detectedProjects.isEmpty {
                monorepoSubProjectPicker
            }

            fieldSection("dev server command (optional)") {
                VStack(alignment: .leading, spacing: 4) {
                    tarsyTextField(devCommandPlaceholder, text: $devServerCommand)
                    if isAnalyzing {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini).tint(TarsyTheme.accentAmber)
                            Text("analyzing repo...")
                                .font(TarsyTheme.font(size: 10))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                    } else if !devServerCommand.isEmpty && (detectedLanguage != nil || detectedFramework != nil) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(TarsyTheme.font(size: 9))
                                .foregroundColor(TarsyTheme.accentMoss)
                            Text("auto-detected")
                                .font(TarsyTheme.font(size: 10))
                                .foregroundColor(TarsyTheme.accentMoss)
                            if let lang = detectedLanguage {
                                Text(lang)
                                    .font(TarsyTheme.font(size: 10))
                                    .foregroundColor(TarsyTheme.accentAmber)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(TarsyTheme.accentAmber.opacity(0.15))
                                    .cornerRadius(3)
                            }
                            if let fw = detectedFramework {
                                Text(fw)
                                    .font(TarsyTheme.font(size: 10))
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
        guard !isScanning else { return }
        isScanning = true
        error = nil

        Task { await performScan() }
    }

    @MainActor
    private func performScan() async {
        // Wait for the WebSocket to the Mac to be ready for data packets.
        // On a cold app launch the view appears before smartConnect finishes
        // (~3s) AND before the relay E2E key exchange completes — and
        // ConnectionManager.send() silently drops data packets in both
        // situations (nil `connection` on LAN pre-ready, `!e2e.isReady`
        // drop on relay). Without this wait the listener never fires and
        // the spinner hangs until the 25s scan timeout, making it feel
        // permanently stuck — but only on the first attempt, because by
        // the time the user retries the handshake is usually complete.
        let ready = await connectionManager.waitUntilReadyToSendData(timeout: 12)
        guard ready else {
            isScanning = false
            error = "mac unreachable — make sure tarsy is running on your mac"
            return
        }

        // Register listener BEFORE sending to avoid race condition.
        connectionManager.addListener("scan_repos") { packet in
            guard packet.action == .workspaceScanResult else { return }

            Task { @MainActor in
                self.connectionManager.removeListener("scan_repos")

                if let json = packet.payload?["repos"],
                   let data = json.data(using: .utf8),
                   let repos = try? JSONDecoder().decode([ScannedRepo].self, from: data) {
                    self.scannedRepos = repos
                } else if let errorMsg = packet.payload?["error"] {
                    self.error = errorMsg
                } else {
                    self.error = "failed to parse repo list from mac"
                }
                self.isScanning = false
            }
        }

        connectionManager.send(WSPacket(action: .workspaceScanRepos))

        // Timeout for the scan response itself — generous to allow concurrent
        // git enrichment on macOS.
        Task {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            await MainActor.run {
                if isScanning {
                    isScanning = false
                    connectionManager.removeListener("scan_repos")
                    self.error = "scan timed out — mac may be unreachable"
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
        // Reset any previous analysis state so the picker doesn't linger
        // between repo selections.
        detectedProjects = []
        selectedProjectPath = nil
        detectedLanguage = nil
        detectedFramework = nil
        devServerCommand = ""
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
                    let isMonorepo: Bool?
                    let projects: [DetectedSubProject]?
                }

                guard let analysis = try? JSONDecoder().decode(Analysis.self, from: data) else {
                    self.error = "failed to analyze repo"
                    return
                }

                // Monorepo path: surface the sub-project picker and auto-pick
                // the first one so the form has sensible defaults.
                if let projects = analysis.projects, !projects.isEmpty {
                    self.detectedProjects = projects
                    if let first = projects.first {
                        self.applySubProject(first)
                    }
                } else {
                    self.detectedProjects = []
                    self.selectedProjectPath = nil

                    // Single-project repo: auto-fill dev server command if empty
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
            var config: [String: String] = [:]
            if let sub = selectedProjectPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), !sub.isEmpty {
                config["subPath"] = sub
            }
            if let lang = detectedLanguage, !lang.isEmpty {
                config["language"] = lang
            }
            if let fw = detectedFramework, !fw.isEmpty {
                config["framework"] = fw
            }
            let request = CreateWorkspaceRequest(
                userId: session.user.id.uuidString,
                machineId: machineId.uuidString,
                name: name,
                repoUrl: repoUrl.isEmpty ? nil : repoUrl,
                localPath: localPath.isEmpty ? "~/Projects/\(name.lowercased())" : localPath,
                stack: stack.rawValue,
                // OpenClaw is temporarily disabled in the UI until the feature
                // is fully implemented — always create standard workspaces.
                workspaceType: Workspace.WorkspaceType.standard.rawValue,
                devServerCommand: devServerCommand.isEmpty ? nil : devServerCommand,
                streamUrl: nil,
                aiContext: nil,
                config: config.isEmpty ? nil : config
            )
            let _ = try await workspaceService.createWorkspace(request)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
    }

    // MARK: - Monorepo sub-project picker

    private var monorepoSubProjectPicker: some View {
        fieldSection("monorepo sub-project") {
            VStack(alignment: .leading, spacing: 8) {
                Text("this repo contains multiple projects — pick the one you want tarsy to run")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(detectedProjects) { project in
                            subProjectChip(project)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func subProjectChip(_ project: DetectedSubProject) -> some View {
        let isSelected = selectedProjectPath == project.path
        Button(action: { applySubProject(project) }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: iconForStack(project.stack))
                        .font(TarsyTheme.font(size: 9))
                    Text(project.name)
                        .font(TarsyTheme.monoFontSmall)
                        .fontWeight(.medium)
                }
                HStack(spacing: 4) {
                    if let fw = project.framework {
                        Text(fw)
                            .font(TarsyTheme.font(size: 9))
                    } else if let lang = project.language {
                        Text(lang)
                            .font(TarsyTheme.font(size: 9))
                    }
                    if let s = project.stack {
                        Text(s)
                            .font(TarsyTheme.font(size: 9))
                            .opacity(0.7)
                    }
                }
            }
            .foregroundColor(isSelected ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.clear : TarsyTheme.backgroundTertiary, lineWidth: 1)
            )
        }
    }

    private func iconForStack(_ stack: String?) -> String {
        switch stack {
        case "mobile": return "iphone"
        case "web": return "globe"
        case "backend": return "server.rack"
        case "fullstack": return "square.stack.3d.up"
        default: return "folder"
        }
    }

    private func applySubProject(_ project: DetectedSubProject) {
        selectedProjectPath = project.path
        detectedLanguage = project.language
        detectedFramework = project.framework

        if let s = project.stack, let ws = Workspace.WorkspaceStack(rawValue: s) {
            stack = ws
        }
        // Always replace the command on sub-project change — the old one
        // belonged to the previous selection and would be wrong now.
        // The persisted workspace already has `subPath` so the cwd will be
        // correct; strip any `cd …  && ` wrapper from the suggested command.
        devServerCommand = stripCdPrefix(project.suggestedCommand ?? "")
    }

    /// RepoAnalyzer suggests commands like `"cd apps/web && npm run dev"` so
    /// they work from the repo root. Once the sub-project is persisted as
    /// `subPath`, the terminal opens directly in that directory and the cd
    /// becomes redundant (and breaks if the user later edits the path).
    private func stripCdPrefix(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("cd ") else { return trimmed }
        guard let separatorRange = trimmed.range(of: "&&") else { return trimmed }
        return trimmed[separatorRange.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    private var devCommandPlaceholder: String {
        switch stack {
        case .web, .fullstack: return "npm run dev"
        case .mobile: return "npx expo start"
        case .backend: return "npm start"
        }
    }

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
}

#if DEBUG
#Preview {
    PreviewWrapper {
        NewWorkspaceView()
    }
}
#endif
