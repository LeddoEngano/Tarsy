import SwiftUI
import TarsyShared

struct AIProjectWizardView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var machineService: MachineService

    enum WizardStep: Int, CaseIterable {
        case idea = 0
        case refining = 1
        case stack = 2
        case summary = 3
        case creating = 4
    }

    // State
    @State private var step: WizardStep = .idea
    @State private var projectIdea = ""
    @State private var selectedEngine: AIEngineType = .claude
    @State private var detectedAgents: [AIEngineType] = [.claude]
    @State private var isWaitingForAI = false
    @State private var error: String?
    @State private var ghAvailable = false

    // AI-generated config
    @State private var wizardConfig = ProjectWizardConfig()
    @State private var aiRawResponse = ""

    // User-editable fields (populated from AI)
    @State private var projectName = ""
    @State private var language = ""
    @State private var framework = ""
    @State private var stack: Workspace.WorkspaceStack = .web
    @State private var projectPath = ""
    @State private var dependencies: [String] = []
    @State private var createOnGitHub = false
    @State private var isCreating = false

    // Suggested options from AI
    @State private var suggestedLanguages: [String] = []
    @State private var suggestedFrameworks: [String] = []
    @State private var suggestedDeps: [String] = []

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Progress bar
                    progressBar

                    ScrollView {
                        VStack(spacing: 24) {
                            switch step {
                            case .idea:
                                ideaStep
                            case .refining:
                                refiningStep
                            case .stack:
                                stackStep
                            case .summary:
                                summaryStep
                            case .creating:
                                creatingStep
                            }
                        }
                        .padding(20)
                    }
                }
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .top) {
                header
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            listenForAgents()
            listenForWizardPackets()
        }
        .onDisappear {
            connectionManager.removeListener("wizard_agents")
            connectionManager.removeListener("wizard_flow")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            if step != .idea && step != .creating {
                Button(action: goBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.caption)
                        Text("back")
                            .font(TarsyTheme.monoFontSmall)
                    }
                    .foregroundColor(TarsyTheme.textSecondary)
                }
            }

            Spacer()

            Text("create with ai")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
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

    // MARK: - Progress Bar

    private var progressBar: some View {
        let totalSteps = 4
        let current = min(step.rawValue, totalSteps)
        return HStack(spacing: 4) {
            ForEach(0..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? TarsyTheme.accentAmber : TarsyTheme.backgroundTertiary)
                    .frame(height: 3)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Step 1: Idea

    private var ideaStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("describe your project")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)

                Text("tell the AI what you want to build. be as detailed as you'd like.")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
            }

            TextEditor(text: $projectIdea)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(TarsyTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(14)
                .frame(minHeight: 140, maxHeight: 240)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if projectIdea.isEmpty {
                        Text("e.g. a Next.js dashboard that tracks crypto prices with real-time charts and alerts...")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))
                            .padding(18)
                            .allowsHitTesting(false)
                    }
                }

            // Agent selector
            VStack(alignment: .leading, spacing: 8) {
                Text("agent")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary)
                    .textCase(.uppercase)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(detectedAgents, id: \.rawValue) { engine in
                            agentChip(engine)
                        }
                    }
                }
            }

            if let error {
                Text(error)
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.accentTerracotta)
            }

            Button(action: submitIdea) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("analyze with ai")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(TarsyTheme.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(projectIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? TarsyTheme.backgroundTertiary : TarsyTheme.accentAmber)
                .cornerRadius(12)
            }
            .disabled(projectIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - Step 2: Refining (AI thinking)

    private var refiningStep: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 40)

            ZStack {
                Circle()
                    .fill(TarsyTheme.accentAmber.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: selectedEngine.iconName)
                    .font(.system(size: 32))
                    .foregroundColor(TarsyTheme.accentAmber)
                    .rotationEffect(.degrees(isWaitingForAI ? 360 : 0))
                    .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: isWaitingForAI)
            }

            VStack(spacing: 8) {
                Text("\(selectedEngine.displayName) is analyzing...")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)

                Text("figuring out the best stack and structure for your project")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if !aiRawResponse.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ai output")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)

                    ScrollView {
                        Text(aiRawResponse)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(10)
                    .background(TarsyTheme.backgroundSecondary)
                    .cornerRadius(8)
                }
            }

            ProgressView()
                .tint(TarsyTheme.accentAmber)
        }
    }

    // MARK: - Step 3: Stack Selection

    private var stackStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("review & customize")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)

                Text("the AI suggested this setup. adjust anything you'd like.")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
            }

            fieldSection("project name") {
                tarsyTextField("my-project", text: $projectName)
            }

            fieldSection("language") {
                if suggestedLanguages.isEmpty {
                    tarsyTextField("TypeScript", text: $language)
                } else {
                    chipSelector(options: suggestedLanguages, selected: $language)
                }
            }

            fieldSection("framework") {
                if suggestedFrameworks.isEmpty {
                    tarsyTextField("Next.js", text: $framework)
                } else {
                    chipSelector(options: suggestedFrameworks, selected: $framework)
                }
            }

            fieldSection("stack type") {
                HStack(spacing: 8) {
                    ForEach([Workspace.WorkspaceStack.web, .mobile, .backend, .fullstack], id: \.rawValue) { s in
                        stackChip(s)
                    }
                }
            }

            if !suggestedDeps.isEmpty {
                fieldSection("dependencies") {
                    FlowLayout(spacing: 6) {
                        ForEach(suggestedDeps, id: \.self) { dep in
                            let isSelected = dependencies.contains(dep)
                            Button {
                                if isSelected {
                                    dependencies.removeAll { $0 == dep }
                                } else {
                                    dependencies.append(dep)
                                }
                            } label: {
                                Text(dep)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(isSelected ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(isSelected ? TarsyTheme.accentMoss : TarsyTheme.backgroundSecondary)
                                    .cornerRadius(6)
                            }
                        }
                    }
                }
            }

            fieldSection("project path") {
                tarsyTextField("~/Projects/my-app", text: $projectPath)
            }

            Button(action: { withAnimation { step = .summary } }) {
                Text("review summary")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(TarsyTheme.accentAmber)
                    .cornerRadius(12)
            }
        }
    }

    // MARK: - Step 4: Summary

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ready to create")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)

                Text("confirm everything looks good, then let the AI build it.")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
            }

            // Summary cards
            summaryCard(icon: "folder.fill", label: "project", value: projectName)
            summaryCard(icon: "chevron.left.forwardslash.chevron.right", label: "language", value: language)
            summaryCard(icon: "hammer.fill", label: "framework", value: framework)
            summaryCard(icon: "square.stack.3d.up.fill", label: "stack", value: stack.rawValue)
            summaryCard(icon: "folder.badge.gearshape", label: "path", value: projectPath)
            summaryCard(icon: selectedEngine.iconName, label: "agent", value: selectedEngine.displayName)

            if !dependencies.isEmpty {
                summaryCard(icon: "shippingbox.fill", label: "dependencies", value: dependencies.joined(separator: ", "))
            }

            // GitHub toggle
            if ghAvailable {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 14))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .frame(width: 24)

                    Text("create GitHub repository")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(TarsyTheme.textPrimary)

                    Spacer()

                    Toggle("", isOn: $createOnGitHub)
                        .labelsHidden()
                        .tint(TarsyTheme.accentAmber)
                }
                .padding(14)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(10)
            }

            if let error {
                Text(error)
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.accentTerracotta)
            }

            Button(action: executeWizard) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                    Text("create project & start agent")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(TarsyTheme.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(TarsyTheme.accentAmber)
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Step 5: Creating

    private var creatingStep: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 60)

            ZStack {
                Circle()
                    .fill(TarsyTheme.accentAmber.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "wand.and.stars")
                    .font(.system(size: 32))
                    .foregroundColor(TarsyTheme.accentAmber)
            }

            VStack(spacing: 8) {
                Text("creating your project...")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)

                Text("setting up repo, workspace, and dispatching agent")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            ProgressView()
                .tint(TarsyTheme.accentAmber)
        }
    }

    // MARK: - Actions

    private func submitIdea() {
        let idea = projectIdea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { return }

        error = nil
        isWaitingForAI = true
        aiRawResponse = ""
        withAnimation { step = .refining }

        // Build the structured prompt for the agent
        let systemPrompt = """
        You are helping set up a new software project. The user will describe what they want to build.

        Analyze the request and respond with ONLY a JSON object (no markdown, no code fences, no explanation) with this exact structure:
        {
            "projectName": "suggested-project-name",
            "projectDescription": "one-line description",
            "language": "primary language",
            "framework": "main framework",
            "suggestedLanguages": ["lang1", "lang2", "lang3"],
            "suggestedFrameworks": ["framework1", "framework2"],
            "dependencies": ["dep1", "dep2", "dep3"],
            "stack": "web|mobile|backend|fullstack",
            "initialPrompt": "detailed prompt to send to the coding agent to scaffold this project"
        }

        Choose the most appropriate technologies. The initialPrompt should be comprehensive — it will be sent directly to a coding agent to create the project from scratch.
        """

        connectionManager.send(WSPacket(
            action: .wizardStart,
            payload: [
                "idea": idea,
                "systemPrompt": systemPrompt,
                "engineType": selectedEngine.rawValue
            ]
        ))
    }

    private func executeWizard() {
        guard let machineId = machineService.machine?.id else {
            error = "no mac connected"
            return
        }

        isCreating = true
        error = nil
        withAnimation { step = .creating }

        // Build the config
        var config = wizardConfig
        config.projectName = projectName
        config.language = language
        config.framework = framework
        config.stack = stack.rawValue
        config.suggestedPath = projectPath
        config.dependencies = dependencies

        let configJson = (try? config.encode()) ?? "{}"

        connectionManager.send(WSPacket(
            action: .wizardExecute,
            payload: [
                "config": configJson,
                "engineType": selectedEngine.rawValue,
                "machineId": machineId.uuidString,
                "createGitHub": createOnGitHub ? "true" : "false",
                "idea": projectIdea
            ]
        ))
    }

    private func goBack() {
        withAnimation {
            switch step {
            case .stack: step = .idea
            case .summary: step = .stack
            default: break
            }
        }
    }

    // MARK: - Packet Listeners

    private func listenForAgents() {
        connectionManager.addListener("wizard_agents") { packet in
            if packet.action == .agentsDetected,
               let csv = packet.payload?["agents"] {
                let engines = csv.split(separator: ",").compactMap { AIEngineType(rawValue: String($0)) }
                Task { @MainActor in
                    if !engines.isEmpty {
                        self.detectedAgents = engines
                        if !engines.contains(self.selectedEngine) {
                            self.selectedEngine = engines.first ?? .claude
                        }
                    }
                }
            }
        }
    }

    private func listenForWizardPackets() {
        connectionManager.addListener("wizard_flow") { packet in
            Task { @MainActor in
                switch packet.action {
                case .wizardResponse:
                    handleWizardResponse(packet)
                case .wizardResult:
                    handleWizardResult(packet)
                case .wizardGhDetected:
                    self.ghAvailable = packet.payload?["available"] == "true"
                default:
                    break
                }
            }
        }
    }

    private func handleWizardResponse(_ packet: WSPacket) {
        guard let response = packet.payload?["response"] else { return }
        aiRawResponse = response
        isWaitingForAI = false

        // Try to parse the JSON from the AI response
        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8) else {
            applyFallbackConfig()
            withAnimation { step = .stack }
            return
        }

        do {
            let parsed = try JSONDecoder().decode(WizardAIResponse.self, from: data)
            projectName = parsed.projectName
            language = parsed.language
            framework = parsed.framework
            suggestedLanguages = parsed.suggestedLanguages ?? []
            suggestedFrameworks = parsed.suggestedFrameworks ?? []
            suggestedDeps = parsed.dependencies ?? []
            dependencies = parsed.dependencies ?? []
            projectPath = "~/Projects/\(parsed.projectName)"

            if let s = Workspace.WorkspaceStack(rawValue: parsed.stack ?? "web") {
                stack = s
            }

            // Store for later
            wizardConfig.projectName = parsed.projectName
            wizardConfig.projectDescription = parsed.projectDescription ?? ""
            wizardConfig.language = parsed.language
            wizardConfig.framework = parsed.framework
            wizardConfig.initialPrompt = parsed.initialPrompt ?? ""

            if !suggestedLanguages.contains(language) {
                suggestedLanguages.insert(language, at: 0)
            }
            if !suggestedFrameworks.contains(framework) {
                suggestedFrameworks.insert(framework, at: 0)
            }
        } catch {
            applyFallbackConfig()
        }

        withAnimation { step = .stack }
    }

    private func handleWizardResult(_ packet: WSPacket) {
        isCreating = false
        if packet.payload?["success"] == "true" {
            // Refresh workspaces and dismiss
            Task {
                await workspaceService.fetchWorkspaces()
                dismiss()
            }
        } else {
            error = packet.payload?["error"] ?? "failed to create project"
            withAnimation { step = .summary }
        }
    }

    private func applyFallbackConfig() {
        if projectName.isEmpty {
            projectName = "my-project"
        }
        if language.isEmpty {
            language = "TypeScript"
            suggestedLanguages = ["TypeScript", "Python", "Swift", "Go"]
        }
        if framework.isEmpty {
            framework = "Next.js"
            suggestedFrameworks = ["Next.js", "Express", "FastAPI", "Vite"]
        }
        projectPath = "~/Projects/\(projectName)"
    }

    private func extractJSON(from text: String) -> String {
        // Try to find JSON between braces
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return text
        }
        return String(text[start...end])
    }

    // MARK: - UI Components

    @ViewBuilder
    private func agentChip(_ engine: AIEngineType) -> some View {
        Button {
            selectedEngine = engine
        } label: {
            HStack(spacing: 6) {
                Image(systemName: engine.iconName)
                    .font(.system(size: 12))
                Text(engine.displayName)
                    .font(.system(size: 12, design: .monospaced))
            }
            .foregroundColor(selectedEngine == engine ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selectedEngine == engine ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private func chipSelector(options: [String], selected: Binding<String>) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { option in
                Button {
                    selected.wrappedValue = option
                } label: {
                    Text(option)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(selected.wrappedValue == option ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selected.wrappedValue == option ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
                        .cornerRadius(8)
                }
            }
        }
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

    @ViewBuilder
    private func summaryCard(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(TarsyTheme.accentAmber)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(14)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(10)
    }

    @ViewBuilder
    private func fieldSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(TarsyTheme.textSecondary)
                .textCase(.uppercase)
            content()
        }
    }

    @ViewBuilder
    private func tarsyTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(TarsyTheme.textSecondary.opacity(0.5)))
            .textFieldStyle(.plain)
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(TarsyTheme.textPrimary)
            .padding(14)
            .background(TarsyTheme.backgroundSecondary)
            .cornerRadius(10)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
    }
}

// MARK: - AI Response Model

private struct WizardAIResponse: Codable {
    let projectName: String
    let projectDescription: String?
    let language: String
    let framework: String
    let suggestedLanguages: [String]?
    let suggestedFrameworks: [String]?
    let dependencies: [String]?
    let stack: String?
    let initialPrompt: String?
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
