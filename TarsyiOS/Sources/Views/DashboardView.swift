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
                        } else {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(machineService.isOnline ? TarsyTheme.statusRunning : TarsyTheme.statusError)
                                    .frame(width: 6, height: 6)
                                Text(machineService.isOnline ? "mac online" : "mac offline")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(TarsyTheme.textSecondary)
                            }
                        }
                    }

                    Spacer()

                    HStack(spacing: 16) {
                        if !workspaceService.workspaces.isEmpty {
                            Button(action: { showQuickDispatch = true }) {
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(TarsyTheme.accentAmber)
                            }
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
                        Button(action: { showActiveSessions = true }) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .foregroundColor(TarsyTheme.textSecondary)
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
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(TarsyTheme.backgroundPrimary)

                // Content
                ZStack {
                    TarsyTheme.backgroundPrimary
                        .ignoresSafeArea()

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
            await workspaceService.fetchWorkspaces()
            await taskService.loadActiveTasks()
            await taskService.cleanupOldTasks()
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
                    HStack {
                        Text(m.name)
                        if m.status == .online {
                            Image(systemName: "circle.fill")
                        }
                        if m.id == machineService.selectedMachineId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
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

    var statusColor: Color {
        switch workspace.status {
        case .running: return TarsyTheme.statusRunning
        case .starting: return TarsyTheme.statusStarting
        case .idle: return TarsyTheme.statusIdle
        case .error: return TarsyTheme.statusError
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

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

            Text(workspace.status.rawValue)
                .font(TarsyTheme.monoFontSmall)
                .foregroundColor(statusColor)
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
