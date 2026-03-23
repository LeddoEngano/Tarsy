import SwiftUI
import TarsyShared

struct DashboardView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var workspaces: [Workspace] = []
    @State private var showNewWorkspace = false

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary
                    .ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(workspaces) { workspace in
                            NavigationLink(destination: WorkspaceView(workspace: workspace)) {
                                WorkspaceCard(workspace: workspace)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("TARSY")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.accentAmber)
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
        .task {
            await loadWorkspaces()
        }
    }

    private func loadWorkspaces() async {
        do {
            workspaces = try await supabase
                .from("workspaces")
                .select()
                .execute()
                .value
        } catch {
            print("Failed to load workspaces: \(error)")
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
            // Status indicator
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
