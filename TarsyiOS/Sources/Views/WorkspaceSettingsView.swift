import SwiftUI
import TarsyShared

struct WorkspaceSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var workspaceService: WorkspaceService

    let workspace: Workspace

    @State private var name: String
    @State private var repoUrl: String
    @State private var localPath: String
    @State private var stack: Workspace.WorkspaceStack
    @State private var devServerCommand: String
    @State private var isSaving = false
    @State private var showDeleteConfirm = false

    init(workspace: Workspace) {
        self.workspace = workspace
        _name = State(initialValue: workspace.name)
        _repoUrl = State(initialValue: workspace.repoUrl ?? "")
        _localPath = State(initialValue: workspace.localPath)
        _stack = State(initialValue: workspace.stack)
        _devServerCommand = State(initialValue: workspace.devServerCommand ?? "")
    }

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    fieldSection("project name") {
                        tarsyTextField("name", text: $name)
                    }

                    fieldSection("repository url") {
                        tarsyTextField("https://github.com/...", text: $repoUrl)
                    }

                    fieldSection("local path") {
                        tarsyTextField("~/Projects/...", text: $localPath)
                    }

                    fieldSection("stack") {
                        HStack(spacing: 8) {
                            ForEach([Workspace.WorkspaceStack.web, .mobile, .backend, .fullstack], id: \.rawValue) { s in
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
                    }

                    fieldSection("dev server command") {
                        tarsyTextField("npm run dev", text: $devServerCommand)
                    }

                    // Save button
                    Button(action: { Task { await save() } }) {
                        Text(isSaving ? "saving..." : "save changes")
                            .font(TarsyTheme.monoFont)
                            .foregroundColor(TarsyTheme.backgroundPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(TarsyTheme.accentAmber)
                            .cornerRadius(12)
                    }
                    .disabled(isSaving)

                    Spacer().frame(height: 20)

                    // Delete button
                    Button(action: { showDeleteConfirm = true }) {
                        Text("delete workspace")
                            .font(TarsyTheme.monoFontSmall)
                            .foregroundColor(TarsyTheme.accentTerracotta)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .alert("delete workspace?", isPresented: $showDeleteConfirm) {
            Button("delete", role: .destructive) {
                Task {
                    try? await workspaceService.deleteWorkspace(id: workspace.id)
                    dismiss()
                }
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("this will remove the workspace from tarsy. files on your mac won't be deleted.")
        }
    }

    private func save() async {
        isSaving = true
        var req = UpdateWorkspaceRequest()
        req.name = name
        req.repoUrl = repoUrl.isEmpty ? nil : repoUrl
        req.localPath = localPath
        req.stack = stack.rawValue
        req.devServerCommand = devServerCommand.isEmpty ? nil : devServerCommand
        try? await workspaceService.updateWorkspace(id: workspace.id, req)
        isSaving = false
        dismiss()
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
