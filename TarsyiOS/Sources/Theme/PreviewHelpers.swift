import SwiftUI
import TarsyShared

#if DEBUG

// MARK: - Preview Environment Wrapper

/// Wraps any view with all the environment objects needed for previews.
/// Usage: PreviewWrapper { MyView() }
struct PreviewWrapper<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    @StateObject private var authManager = AuthManager()
    @StateObject private var connectionManager = ConnectionManager()
    @StateObject private var workspaceService = WorkspaceService()
    @StateObject private var machineService = MachineService()
    @StateObject private var profileService = ProfileService()
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var deepLinkRouter = DeepLinkRouter()

    var body: some View {
        content()
            .environmentObject(authManager)
            .environmentObject(connectionManager)
            .environmentObject(workspaceService)
            .environmentObject(machineService)
            .environmentObject(profileService)
            .environmentObject(subscriptionManager)
            .environmentObject(deepLinkRouter)
            .preferredColorScheme(.dark)
    }
}

// MARK: - Mock Workspace

enum PreviewData {
    static var workspace: Workspace {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "user_id": "22222222-2222-2222-2222-222222222222",
            "machine_id": "33333333-3333-3333-3333-333333333333",
            "name": "tarsy-app",
            "repo_url": "https://github.com/user/tarsy",
            "local_path": "/Users/dev/projects/tarsy",
            "stack": "fullstack",
            "status": "running",
            "workspace_type": "standard",
            "current_branch": "main",
            "dev_server_command": "npm run dev",
            "created_at": "2026-03-01T12:00:00Z",
            "updated_at": "2026-03-30T12:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(Workspace.self, from: json.data(using: .utf8)!)
    }

    static var idleWorkspace: Workspace {
        let json = """
        {
            "id": "44444444-4444-4444-4444-444444444444",
            "user_id": "22222222-2222-2222-2222-222222222222",
            "machine_id": "33333333-3333-3333-3333-333333333333",
            "name": "landing-page",
            "local_path": "/Users/dev/projects/landing",
            "stack": "web",
            "status": "idle",
            "workspace_type": "standard",
            "current_branch": "feature/redesign",
            "created_at": "2026-03-15T12:00:00Z",
            "updated_at": "2026-03-28T12:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(Workspace.self, from: json.data(using: .utf8)!)
    }
}

#endif
