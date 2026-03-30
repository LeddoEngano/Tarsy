import SwiftUI
import TarsyShared

struct DashboardView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var machineService: MachineService

    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var profileService: ProfileService
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @StateObject private var taskService = AgentTaskService()
    @State private var showNewWorkspace = false
    @State private var showProfile = false
    @State private var showPaywall = false
    @State private var showQuickDispatch = false
    @State private var showActiveSessions = false
    @State private var showAIWizard = false
    @State private var deepLinkWorkspace: Workspace?
    @State private var isDeepLinkActive = false
    @State private var hasFetchedMachines = false
    @State private var machineStatusTimer: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Custom header
                HStack {
                    HStack(spacing: 8) {
                        Text("TARSY")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(TarsyTheme.accentAmber)

                        if machineService.machines.count > 1 {
                            machinePicker
                        } else if !machineService.machines.isEmpty {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(machineService.isOnline ? TarsyTheme.statusRunning : TarsyTheme.statusError)
                                    .frame(width: 6, height: 6)
                                Text(machineService.isOnline ? "mac online" : "mac offline")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(TarsyTheme.textSecondary)
                            }
                        } else if hasFetchedMachines {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(TarsyTheme.statusIdle)
                                    .frame(width: 6, height: 6)
                                Text("no mac connected")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(TarsyTheme.textSecondary)
                            }
                        }
                    }

                    Spacer()

                    HStack(spacing: 16) {
                        if !machineService.machines.isEmpty {
                            if !workspaceService.workspaces.isEmpty {
                                Button(action: { showQuickDispatch = true }) {
                                    Image(systemName: "bolt.fill")
                                        .foregroundColor(TarsyTheme.accentAmber)
                                }
                                .accessibilityLabel("Quick dispatch")
                            }
                            Button(action: {
                                if subscriptionManager.canCreateWorkspace(currentCount: workspaceService.workspaces.count) {
                                    showAIWizard = true
                                } else {
                                    showPaywall = true
                                }
                            }) {
                                Image(systemName: "wand.and.stars")
                                    .foregroundColor(TarsyTheme.accentAmber)
                            }
                            .accessibilityLabel("AI project wizard")
                            Button(action: {
                                if subscriptionManager.canCreateWorkspace(currentCount: workspaceService.workspaces.count) {
                                    showNewWorkspace = true
                                } else {
                                    showPaywall = true
                                }
                            }) {
                                Image(systemName: "plus")
                                    .foregroundColor(TarsyTheme.accentAmber)
                            }
                            .accessibilityLabel("New workspace")
                            Button(action: { showActiveSessions = true }) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundColor(TarsyTheme.textSecondary)
                            }
                            .accessibilityLabel("Active sessions")
                        }
                        Button(action: { showProfile = true }) {
                            if let avatarUrlStr = profileService.profile?.avatarUrl, let url = URL(string: avatarUrlStr) {
                                AsyncImage(url: url) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Image(systemName: "person.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(TarsyTheme.textSecondary)
                                }
                                .frame(width: 26, height: 26)
                                .clipShape(Circle())
                            } else {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(TarsyTheme.textSecondary)
                            }
                        }
                        .accessibilityLabel("Profile")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(TarsyTheme.backgroundPrimary)

                // Content
                ZStack {
                    TarsyTheme.backgroundPrimary
                        .ignoresSafeArea()

                    if machineService.machines.isEmpty && hasFetchedMachines {
                        machineSetupGuide
                    } else {
                        if !taskService.activeTasks.isEmpty {
                            activeTasksSection
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                        }

                        if workspaceService.isLoading && workspaceService.workspaces.isEmpty {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .tint(TarsyTheme.accentAmber)
                                Text("loading workspaces...")
                                    .font(TarsyTheme.monoFontSmall)
                                    .foregroundColor(TarsyTheme.textSecondary)
                            }
                        } else if filteredWorkspaces.isEmpty {
                            emptyState
                        } else {
                            workspaceList
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: $isDeepLinkActive) {
                if let ws = deepLinkWorkspace {
                    WorkspaceView(workspace: ws)
                }
            }
        }
        .sheet(isPresented: $showNewWorkspace) {
            NewWorkspaceView()
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showQuickDispatch) {
            QuickDispatchView(workspaces: workspaceService.workspaces)
        }
        .sheet(isPresented: $showActiveSessions) {
            ActiveSessionsView()
        }
        .sheet(isPresented: $showAIWizard) {
            AIProjectWizardView()
        }
        .task {
            await machineService.fetchMachine()
            hasFetchedMachines = true
            await workspaceService.fetchWorkspaces()
            await taskService.loadActiveTasks()
            await taskService.cleanupOldTasks()
        }
        .onAppear {
            // Poll machine status with jitter (25-35s) to avoid thundering herd
            let interval = 30.0 + Double.random(in: -5...5)
            machineStatusTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                Task { await machineService.fetchMachine() }
            }
        }
        .onDisappear {
            machineStatusTimer?.invalidate()
            machineStatusTimer = nil
        }
        .onChange(of: deepLinkRouter.pendingWorkspaceId) { _, wsId in
            guard let wsId else { return }
            if let workspace = workspaceService.workspaces.first(where: { $0.id == wsId }) {
                deepLinkWorkspace = workspace
                isDeepLinkActive = true
            }
            deepLinkRouter.pendingWorkspaceId = nil
        }
    }

    // MARK: - Machine Setup Guide

    private var machineSetupGuide: some View {
        ScrollView {
            VStack(spacing: 32) {
                Spacer().frame(height: 24)

                // Header
                VStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 48))
                        .foregroundColor(TarsyTheme.accentAmber)

                    Text("connect your mac")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.textPrimary)

                    Text("tarsy needs a companion app running\non your mac to get started")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                // Steps
                VStack(spacing: 0) {
                    setupStep(
                        number: "1",
                        icon: "arrow.down.circle",
                        title: "download tarsy for mac",
                        description: "get the companion app from tarsy.dev",
                        isLast: false
                    )

                    setupStep(
                        number: "2",
                        icon: "person.badge.key",
                        title: "sign in with the same account",
                        description: "use the same login method you used here",
                        isLast: false
                    )

                    setupStep(
                        number: "3",
                        icon: "checkmark.shield",
                        title: "grant permissions",
                        description: "screen recording, accessibility, and file access",
                        isLast: false
                    )

                    setupStep(
                        number: "4",
                        icon: "wifi",
                        title: "your mac appears here",
                        description: "automatic — works on the same network or remotely",
                        isLast: true
                    )
                }
                .padding(16)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
                )
                .padding(.horizontal, 16)

                // Download button
                Link(destination: URL(string: "https://tarsy.dev")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 14, weight: .semibold))
                        Text("download for mac")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(TarsyTheme.accentAmber)
                    .cornerRadius(10)
                }
                .padding(.horizontal, 16)

                // Refresh hint
                Button(action: {
                    Task {
                        await machineService.fetchMachine()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                        Text("already installed? tap to refresh")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundColor(TarsyTheme.textSecondary)
                }

                Spacer()
            }
        }
        .refreshable {
            await machineService.fetchMachine()
        }
    }

    private func setupStep(number: String, icon: String, title: String, description: String, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Left: number circle + connector line
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(TarsyTheme.accentAmber.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Text(number)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.accentAmber)
                }

                if !isLast {
                    Rectangle()
                        .fill(TarsyTheme.backgroundTertiary)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 32)

            // Right: content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(TarsyTheme.accentAmber)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(TarsyTheme.textPrimary)
                }

                Text(description)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
            .padding(.bottom, isLast ? 0 : 20)

            Spacer()
        }
    }

    // MARK: - Empty State (no workspaces)

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye")
                .font(.system(size: 48))
                .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))

            Text("no workspaces yet")
                .font(TarsyTheme.monoFont)
                .foregroundColor(TarsyTheme.textSecondary)

            Button(action: { showNewWorkspace = true }) {
                Text("create your first workspace")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.accentAmber)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(TarsyTheme.accentAmber, lineWidth: 1)
                    )
            }
        }
    }

    private var activeTasksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("active tasks")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(TarsyTheme.textSecondary)
                .textCase(.uppercase)

            ForEach(taskService.activeTasks) { task in
                if let workspace = workspaceService.workspaces.first(where: { $0.id == task.workspaceId }) {
                    NavigationLink(destination: WorkspaceView(workspace: workspace)) {
                        taskRow(task)
                    }
                    .buttonStyle(.plain)
                } else {
                    taskRow(task)
                }
            }
        }
    }

    private func taskRow(_ task: AgentTask) -> some View {
        HStack(spacing: 10) {
            Group {
                switch task.status {
                case .running:
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(TarsyTheme.accentAmber)
                case .waiting:
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundColor(TarsyTheme.accentAmber)
                case .completed:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(TarsyTheme.accentMoss)
                case .error:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(TarsyTheme.accentTerracotta)
                }
            }
            .font(.system(size: 14))
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.description)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let engine = task.engineType {
                        Text(engine)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(TarsyTheme.accentAmber)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(TarsyTheme.accentAmber.opacity(0.15))
                            .cornerRadius(3)
                    }
                    Text(task.status.rawValue)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10))
                .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
        }
        .padding(10)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(8)
    }

    private var filteredWorkspaces: [Workspace] {
        guard machineService.machines.count > 1,
              let selectedId = machineService.selectedMachineId else {
            return workspaceService.workspaces
        }
        return workspaceService.workspaces.filter { $0.machineId == selectedId }
    }

    private var machinePicker: some View {
        Menu {
            ForEach(machineService.machines) { m in
                Button {
                    machineService.selectMachine(m.id)
                } label: {
                    Label {
                        Text(m.name)
                    } icon: {
                        Image(systemName: m.deviceIcon)
                    }
                    if m.status == .online {
                        Image(systemName: "circle.fill")
                    }
                    if m.id == machineService.selectedMachineId {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: machineService.selectedMachine?.deviceIcon ?? "desktopcomputer")
                    .font(.system(size: 12))
                    .foregroundColor(TarsyTheme.accentAmber)
                Circle()
                    .fill(machineService.isOnline ? TarsyTheme.statusRunning : TarsyTheme.statusError)
                    .frame(width: 6, height: 6)
                Text(machineService.selectedMachine?.name ?? "select mac")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
        }
    }

    private var workspaceList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredWorkspaces) { workspace in
                    NavigationLink(destination: WorkspaceView(workspace: workspace)) {
                        WorkspaceCard(workspace: workspace)
                    }
                    .contextMenu {
                        NavigationLink(destination: AIContextEditorView(workspace: workspace).environmentObject(workspaceService)) {
                            Label("edit ai context", systemImage: "brain")
                        }
                        NavigationLink(destination: WorkspaceSettingsView(workspace: workspace).environmentObject(workspaceService)) {
                            Label("settings", systemImage: "gearshape")
                        }
                        Button(role: .destructive) {
                            Task { try? await workspaceService.deleteWorkspace(id: workspace.id) }
                        } label: {
                            Label("delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(16)
        }
        .refreshable {
            await machineService.fetchMachine()
            await workspaceService.fetchWorkspaces()
            await taskService.loadActiveTasks()
        }
    }
}

struct WorkspaceCard: View {
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.name)
                    .font(TarsyTheme.monoFont)
                    .foregroundColor(TarsyTheme.textPrimary)
                    .fontWeight(.semibold)

                HStack(spacing: 8) {
                    if let branch = workspace.currentBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textSecondary)
                    }

                    Text(workspace.stack.rawValue)
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.accentAmber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TarsyTheme.accentAmber.opacity(0.15))
                        .cornerRadius(4)
                }
            }

            Spacer()

            // AI context indicator
            if workspace.aiContext != nil {
                Image(systemName: "brain")
                    .font(.caption)
                    .foregroundColor(TarsyTheme.accentMoss)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(TarsyTheme.textSecondary)
        }
        .padding(16)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
        )
    }
}

#if DEBUG
#Preview {
    PreviewWrapper {
        DashboardView()
    }
}
#endif
