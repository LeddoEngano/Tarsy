import SwiftUI
import TarsyShared

struct DashboardView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var machineService: MachineService
    @EnvironmentObject var connectionManager: ConnectionManager

    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var profileService: ProfileService
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    @EnvironmentObject var badgeService: NotificationBadgeService
    @StateObject private var taskService = AgentTaskService()
    @State private var showNewWorkspace = false
    @State private var showProfile = false
    @State private var showPaywall = false
    @State private var showActiveSessions = false
    // MARK: - Hidden for App Store review (re-enable after approval)
//    @State private var showQuickDispatch = false
//    @State private var showAIWizard = false
    @State private var showFeedback = false
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
                        TarsyEyes(size: 32, animated: false)
                        Text("tarsy")
                            .font(TarsyTheme.font(size: 24, weight: .bold))
                            .foregroundColor(TarsyTheme.accentAmber)
                    }

                    Spacer()

                    HStack(spacing: 16) {
                        if !machineService.machines.isEmpty {
                            // MARK: - Hidden for App Store review (re-enable after approval)
//                            if !workspaceService.workspaces.isEmpty {
//                                Button(action: { showQuickDispatch = true }) {
//                                    Image(systemName: "bolt.fill")
//                                        .foregroundColor(TarsyTheme.accentAmber)
//                                }
//                                .accessibilityLabel("Quick dispatch")
//                            }
//                            Button(action: {
//                                if subscriptionManager.canCreateWorkspace(currentCount: workspaceService.workspaces.count) {
//                                    showAIWizard = true
//                                } else {
//                                    showPaywall = true
//                                }
//                            }) {
//                                Image(systemName: "wand.and.stars")
//                                    .foregroundColor(TarsyTheme.accentAmber)
//                            }
//                            .accessibilityLabel("AI project wizard")
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
                                        .font(TarsyTheme.font(size: 22))
                                        .foregroundColor(TarsyTheme.textSecondary)
                                }
                                .frame(width: 26, height: 26)
                                .clipShape(Circle())
                            } else {
                                Image(systemName: "person.circle.fill")
                                    .font(TarsyTheme.font(size: 22))
                                    .foregroundColor(TarsyTheme.textSecondary)
                            }
                        }
                        .accessibilityLabel("Profile")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(TarsyTheme.backgroundPrimary)

                // Machine picker row
                if !machineService.machines.isEmpty {
                    HStack {
                        machinePicker
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .background(TarsyTheme.backgroundPrimary)
                } else if hasFetchedMachines {
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(TarsyTheme.statusIdle)
                                .frame(width: 6, height: 6)
                            Text("no mac connected")
                                .font(TarsyTheme.font(size: 10))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .background(TarsyTheme.backgroundPrimary)
                }

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
            .overlay(alignment: .bottomTrailing) {
                Button {
                    showFeedback = true
                } label: {
                    Image(systemName: "megaphone")
                        .font(TarsyTheme.font(size: 16))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .frame(width: 42, height: 42)
                        .background(TarsyTheme.backgroundSecondary)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
                        )
                }
                .accessibilityLabel("Send feedback")
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }
            .navigationBarHidden(true)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
        // MARK: - Hidden for App Store review (re-enable after approval)
//        .sheet(isPresented: $showQuickDispatch) {
//            QuickDispatchView(workspaces: workspaceService.workspaces)
//        }
        .sheet(isPresented: $showFeedback) {
            FeedbackView()
        }
        .sheet(isPresented: $showActiveSessions) {
            ActiveSessionsView()
        }
        .fullScreenCover(isPresented: $showQRScanner) {
            QRScannerView()
                .environmentObject(machineService)
                .environmentObject(connectionManager)
        }
        // MARK: - Hidden for App Store review (re-enable after approval)
//        .sheet(isPresented: $showAIWizard) {
//            AIProjectWizardView()
//        }
        .task {
            await machineService.fetchMachine()
            hasFetchedMachines = true
            await workspaceService.fetchWorkspaces()
            await taskService.loadActiveTasks()
            await taskService.cleanupOldTasks()
            await badgeService.refreshCounts()
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
        .onChange(of: deepLinkRouter.pendingPairing) { _, pairing in
            guard let pairing else { return }
            deepLinkRouter.pendingPairing = nil
            Task {
                let service = PairingService()
                do {
                    _ = try await service.claimMachine(machineId: pairing.machineId, pairingToken: pairing.token)
                    await machineService.fetchMachine()
                    if machineService.isOnline {
                        let session = try await supabase.auth.session
                        connectionManager.smartConnect(
                            lanHost: machineService.bestIP,
                            port: TarsyConfig.websocketPort,
                            token: session.accessToken
                        )
                    }
                } catch {
                    #if DEBUG
                    print("[DeepLink] Pairing failed: \(error)")
                    #endif
                }
            }
        }
    }

    // MARK: - Machine Setup Guide

    @State private var showQRScanner = false

    private var machineSetupGuide: some View {
        ScrollView {
        VStack(spacing: 0) {
            Spacer()

            // Logo + branding
            TarsyEyes(size: 80)
                .padding(.bottom, 20)

            Text("tarsy")
                .font(TarsyTheme.font(size: 28, weight: .bold))
                .foregroundColor(TarsyTheme.textPrimary)
                .padding(.bottom, 4)

            Text("remote agent controller")
                .font(TarsyTheme.font(size: 13))
                .foregroundColor(TarsyTheme.textSecondary)
                .padding(.bottom, 40)

            // Scan button
            Button(action: { showQRScanner = true }) {
                HStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(TarsyTheme.font(size: 16))
                    Text("Scan to Connect Mac")
                        .font(TarsyTheme.font(size: 15, weight: .medium))
                }
                .foregroundColor(TarsyTheme.backgroundPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(TarsyTheme.textAccent)
                )
            }
            .padding(.horizontal, 40)

            Spacer()

            // Terms / Privacy
            HStack(spacing: 4) {
                Text("By continuing, you agree to our")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
            HStack(spacing: 4) {
                Link("Terms of Service", destination: URL(string: "https://tarsy.dev/terms")!)
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textPrimary)
                Text("and")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)
                Link("Privacy Policy", destination: URL(string: "https://tarsy.dev/privacy")!)
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textPrimary)
            }
            .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity)
        }
        .refreshable {
            await machineService.fetchMachine()
        }
    }

    // MARK: - Empty State (no workspaces)

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye")
                .font(TarsyTheme.font(size: 48))
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
                .font(TarsyTheme.font(size: 11, weight: .semibold))
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
            .font(TarsyTheme.font(size: 14))
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.description)
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let engine = task.engineType {
                        Text(engine)
                            .font(TarsyTheme.font(size: 9))
                            .foregroundColor(TarsyTheme.accentAmber)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(TarsyTheme.accentAmber.opacity(0.15))
                            .cornerRadius(3)
                    }
                    Text(task.status.rawValue)
                        .font(TarsyTheme.font(size: 9))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(TarsyTheme.font(size: 10))
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

            Divider()

            Button {
                showQRScanner = true
            } label: {
                Label("Add Mac...", systemImage: "qrcode.viewfinder")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: machineService.selectedMachine?.deviceIcon ?? "desktopcomputer")
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(TarsyTheme.accentAmber)
                Circle()
                    .fill(machineService.isOnline ? TarsyTheme.statusRunning : TarsyTheme.statusError)
                    .frame(width: 6, height: 6)
                Text(machineService.selectedMachine?.name ?? "select mac")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(TarsyTheme.font(size: 8))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
        }
    }

    private var workspaceList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredWorkspaces) { workspace in
                    NavigationLink(destination: WorkspaceView(workspace: workspace)) {
                        WorkspaceCard(workspace: workspace, unreadCount: badgeService.unreadCounts[workspace.id] ?? 0)
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
            await badgeService.refreshCounts()
        }
    }
}

struct WorkspaceCard: View {
    let workspace: Workspace
    var unreadCount: Int = 0

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
        .overlay(alignment: .topTrailing) {
            if unreadCount > 0 {
                Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                    .font(TarsyTheme.font(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(TarsyTheme.accentTerracotta)
                    .clipShape(Capsule())
                    .offset(x: -8, y: 8)
            }
        }
    }
}

#if DEBUG
#Preview {
    PreviewWrapper {
        DashboardView()
    }
}
#endif
