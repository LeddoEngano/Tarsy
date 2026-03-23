import SwiftUI
import TarsyShared

struct NewWorkspaceView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var workspaceService: WorkspaceService
    @EnvironmentObject var machineService: MachineService

    @State private var name = ""
    @State private var repoUrl = ""
    @State private var localPath = "~/Projects/"
    @State private var stack: Workspace.WorkspaceStack = .web
    @State private var devServerCommand = ""
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                TarsyTheme.backgroundPrimary
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Name
                        fieldSection("project name") {
                            tarsyTextField("EDONext", text: $name)
                        }

                        // Repo URL
                        fieldSection("repository url (optional)") {
                            tarsyTextField("https://github.com/user/repo.git", text: $repoUrl)
                                .keyboardType(.URL)
                        }

                        // Local path
                        fieldSection("local path on mac") {
                            tarsyTextField("~/Projects/my-app", text: $localPath)
                        }

                        // Stack
                        fieldSection("stack") {
                            HStack(spacing: 8) {
                                ForEach([Workspace.WorkspaceStack.web, .mobile, .backend, .fullstack], id: \.rawValue) { s in
                                    stackChip(s)
                                }
                            }
                        }

                        // Dev server command
                        fieldSection("dev server command (optional)") {
                            tarsyTextField("npm run dev", text: $devServerCommand)
                        }

                        if let error {
                            Text(error)
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(TarsyTheme.accentTerracotta)
                        }

                        // Create button
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
                    .padding(20)
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("new workspace")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.accentAmber)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("cancel") { dismiss() }
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }
            .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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
                localPath: localPath.hasSuffix("/") ? localPath + name.lowercased() : localPath,
                stack: stack.rawValue,
                devServerCommand: devServerCommand.isEmpty ? nil : devServerCommand,
                aiContext: nil
            )
            let _ = try await workspaceService.createWorkspace(request)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        isCreating = false
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
