import Foundation
import TarsyShared

@MainActor
class DaemonManager: ObservableObject {
    @Published var isRunning = false
    @Published var activeWorkspaces: [Workspace] = []
    @Published var connectedClients = 0

    func start() {
        isRunning = true
        // TODO: Start WebSocket server
        // TODO: Start heartbeat to Supabase
    }

    func stop() {
        isRunning = false
        // TODO: Stop all services
    }
}
