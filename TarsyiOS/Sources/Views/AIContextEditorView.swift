import SwiftUI
import TarsyShared

struct AIContextEditorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var workspaceService: WorkspaceService

    let workspace: Workspace
    @State private var context: String
    @State private var isSaving = false
    @FocusState private var isFocused: Bool

    init(workspace: Workspace) {
        self.workspace = workspace
        _context = State(initialValue: workspace.aiContext ?? "")
    }

    // Mirrors the CHECK constraint in supabase/migrations/032_ai_context_secret_guard.sql.
    // Keep in sync with that file. Returns the human-readable name of the first
    // matching provider, or nil if the context is clean.
    private var detectedSecret: String? {
        AIContextSecretScanner.firstMatch(in: context)
    }

    private var isValid: Bool { detectedSecret == nil }

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header hint
                HStack {
                    Image(systemName: "brain")
                        .foregroundColor(TarsyTheme.accentAmber)
                    Text("this context is sent to the AI agent before each task")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TarsyTheme.accentAmber.opacity(0.1))

                // Secret detected banner (only when matched)
                if let provider = detectedSecret {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("possible \(provider) credential detected")
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(.red)
                            Text("remove it before saving — api keys must never be stored in ai context")
                                .font(TarsyTheme.monoFontSmall)
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                }

                // Editor
                TextEditor(text: $context)
                    .font(TarsyTheme.font(size: 14))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .background(TarsyTheme.backgroundPrimary)
                    .focused($isFocused)
                    .padding(12)

                // Bottom bar
                HStack {
                    Text("\(context.components(separatedBy: .newlines).count) lines")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)

                    Spacer()

                    Button(action: { Task { await save() } }) {
                        HStack(spacing: 6) {
                            if isSaving {
                                ProgressView()
                                    .tint(TarsyTheme.backgroundPrimary)
                                    .scaleEffect(0.7)
                            }
                            Text(isSaving ? "saving..." : "save")
                                .font(TarsyTheme.monoFontSmall)
                        }
                        .foregroundColor(TarsyTheme.backgroundPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isValid ? TarsyTheme.accentAmber : TarsyTheme.accentAmber.opacity(0.35))
                        .cornerRadius(8)
                    }
                    .disabled(isSaving || !isValid)
                }
                .padding(12)
                .background(TarsyTheme.backgroundSecondary)
            }
        }
        .navigationTitle("ai context")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TarsyTheme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: { insertTemplate(.projectOverview) }) {
                        Label("project overview", systemImage: "doc")
                    }
                    Button(action: { insertTemplate(.codingStyle) }) {
                        Label("coding style", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button(action: { insertTemplate(.testing) }) {
                        Label("testing rules", systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "plus.rectangle")
                        .foregroundColor(TarsyTheme.accentAmber)
                }
            }
        }
        .onAppear { isFocused = true }
    }

    private func save() async {
        isSaving = true
        try? await workspaceService.updateAIContext(workspaceId: workspace.id, context: context)
        isSaving = false
        dismiss()
    }

    private enum ContextTemplate {
        case projectOverview, codingStyle, testing
    }

    private func insertTemplate(_ template: ContextTemplate) {
        let text: String
        switch template {
        case .projectOverview:
            text = """

            ## Project Overview
            - Name:
            - Stack:
            - Description:
            - Key directories:

            """
        case .codingStyle:
            text = """

            ## Coding Style
            - Language:
            - Formatting:
            - Naming conventions:
            - Patterns to follow:
            - Patterns to avoid:

            """
        case .testing:
            text = """

            ## Testing
            - Test framework:
            - Test command:
            - Coverage requirements:
            - What to test:

            """
        }
        context += text
    }
}

#if DEBUG
#Preview {
    AIContextEditorView(workspace: PreviewData.workspace)
        .environmentObject(WorkspaceService())
        .preferredColorScheme(.dark)
}
#endif
