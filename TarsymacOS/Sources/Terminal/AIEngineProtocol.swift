import Foundation
import TarsyShared

protocol AIEngine: Actor {
    var id: String { get }
    var engineType: AIEngineType { get }
    var workspacePath: String { get }

    func setHandlers(
        onOutput: @escaping @Sendable (String) -> Void,
        onComplete: @escaping @Sendable (String) -> Void
    )
    func setAskUserHandler(_ handler: @escaping @Sendable (String, [String]) -> Void)
    func start() throws
    func sendMessage(_ message: String)
    func respondToQuestion(_ answer: String)
    func terminate()
}
