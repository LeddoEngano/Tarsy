import SwiftUI
import TarsyShared

struct DashboardView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var machineService: MachineService

    @State private var showNewWorkspace = false

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary
                    .ignoresSafeArea()

                if workspaceService.isLoading && workspaceService.workspaces.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(TarsyTheme.accentAmber)
                        Text("loading workspaces...")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                } else if workspaceService.workspaces.isEmpty {
                    emptyState
                } else {
                    workspaceList
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 10) {
                        Text("TARSY")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(TarsyTheme.accentAmber)

                        // Machine status
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
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button(action: { showNewWorkspace = true }) {
                            Image(systemName: "plus")
                                .foregroundColor(TarsyTheme.accentAmber)
                        }
                        Button(action: {
                            Task { await authManager.signOut() }
                        }) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                    }
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showNewWorkspace) {
            NewWorkspaceView()
                .environmentObject(workspaceService)
                .environmentObject(machineService)
        }
        .task {
            await machineService.fetchMachine()
            await workspaceService.fetchWorkspaces()
        }
        .refreshable {
            await machineService.fetchMachine()
            await workspaceService.fetchWorkspaces()
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

    private var workspaceList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(workspaceService.workspaces) { workspace in
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
