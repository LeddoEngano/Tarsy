import SwiftUI
import TarsyShared

/// One-shot prompt shown when an existing workspace has no `subPath` saved
/// but its `localPath` turns out to be a monorepo. Re-runs `repoAnalyze` on
/// the macOS daemon and lets the user pick the sub-project once — the choice
/// is persisted to the `config` jsonb so the prompt never re-appears.
///
/// Existed because workspaces created before sub-path persistence shipped
/// have an empty `subPath` and would otherwise need to be deleted and
/// recreated to land in the right cwd.
struct MonorepoMigrationSheet: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var connectionManager: ConnectionManager

    let workspace: Workspace
    let projects: [DetectedSubProject]

    @State private var selectedPath: String? = nil
    @State private var isSaving = false
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("monorepo detected")
                                .font(TarsyTheme.font(size: 20, weight: .bold))
                                .foregroundColor(TarsyTheme.accentAmber)
                            Text("this workspace points at a repo with multiple projects. pick the one tarsy should run commands and agents in.")
                                .font(TarsyTheme.font(size: 12))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }

                        VStack(spacing: 8) {
                            ForEach(projects) { project in
                                projectRow(project)
                            }
                        }

                        if let error {
                            Text(error)
                                .font(TarsyTheme.font(size: 11))
                                .foregroundColor(TarsyTheme.accentTerracotta)
                        }

                        Button(action: { Task { await save() } }) {
                            Text(isSaving ? "saving..." : "save")
                                .font(TarsyTheme.monoFont)
                                .foregroundColor(TarsyTheme.backgroundPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(16)
                                .background(selectedPath == nil ? TarsyTheme.backgroundTertiary : TarsyTheme.accentAmber)
                                .cornerRadius(12)
                        }
                        .disabled(selectedPath == nil || isSaving)

                        Button(action: { Task { await skip() } }) {
                            Text("use repo root instead")
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(TarsyTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .disabled(isSaving)
                    }
                    .padding(20)
                }
            }
            .navigationBarHidden(true)
        }
    }

    @ViewBuilder
    private func projectRow(_ project: DetectedSubProject) -> some View {
        let isSelected = selectedPath == project.path
        Button(action: { selectedPath = project.path }) {
            HStack(spacing: 12) {
                Image(systemName: iconForStack(project.stack))
                    .font(TarsyTheme.font(size: 14))
                    .foregroundColor(isSelected ? TarsyTheme.backgroundPrimary : TarsyTheme.textSecondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(TarsyTheme.monoFont)
                        .foregroundColor(isSelected ? TarsyTheme.backgroundPrimary : TarsyTheme.textPrimary)
                    HStack(spacing: 6) {
                        Text(project.path)
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(isSelected ? TarsyTheme.backgroundPrimary.opacity(0.7) : TarsyTheme.textSecondary)
                        if let fw = project.framework {
                            Text("· \(fw)")
                                .font(TarsyTheme.font(size: 10))
                                .foregroundColor(isSelected ? TarsyTheme.backgroundPrimary.opacity(0.7) : TarsyTheme.textSecondary)
                        } else if let lang = project.language {
                            Text("· \(lang)")
                                .font(TarsyTheme.font(size: 10))
                                .foregroundColor(isSelected ? TarsyTheme.backgroundPrimary.opacity(0.7) : TarsyTheme.textSecondary)
                        }
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(TarsyTheme.backgroundPrimary)
                }
            }
            .padding(14)
            .background(isSelected ? TarsyTheme.accentAmber : TarsyTheme.backgroundSecondary)
            .cornerRadius(10)
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

    /// Persist the chosen sub-project. Merges into the existing `config`
    /// jsonb so we don't blow away `language`/`framework` keys saved by
    /// earlier workspace creation flows.
    private func save() async {
        guard let chosen = selectedPath else { return }
        isSaving = true
        let cleaned = chosen
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var merged = workspace.config ?? [:]
        merged["subPath"] = cleaned
        merged["subPathConfigured"] = "true"
        // If RepoAnalyzer surfaced a more specific language/framework for the
        // selected sub-project, prefer those over whatever the root-level
        // analysis stored.
        if let project = projects.first(where: { $0.path == chosen }) {
            if let lang = project.language, !lang.isEmpty { merged["language"] = lang }
            if let fw = project.framework, !fw.isEmpty { merged["framework"] = fw }
        }

        var req = UpdateWorkspaceRequest()
        req.config = merged
        do {
            try await workspaceService.updateWorkspace(id: workspace.id, req)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isSaving = false
        }
    }

    /// User chose to keep the workspace pointed at the repo root. Persist
    /// the configured marker so we don't re-prompt next time.
    private func skip() async {
        isSaving = true
        var merged = workspace.config ?? [:]
        merged["subPathConfigured"] = "true"
        merged.removeValue(forKey: "subPath")

        var req = UpdateWorkspaceRequest()
        req.config = merged
        do {
            try await workspaceService.updateWorkspace(id: workspace.id, req)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isSaving = false
        }
    }
}
