import SwiftUI
import TarsyShared

@main
struct TarsyiOSApp: App {
    @StateObject private var authManager = AuthManager()
    @StateObject private var workspaceService = WorkspaceService()
    @StateObject private var machineService = MachineService()
    @StateObject private var connectionManager = ConnectionManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authManager)
                .environmentObject(workspaceService)
                .environmentObject(machineService)
                .environmentObject(connectionManager)
        }
    }
}
