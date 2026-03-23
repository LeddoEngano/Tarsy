import Foundation
import TarsyShared

actor OpenClawService {
    private let gatewayPort: UInt16 = 18789
    private var isGatewayRunning = false

    struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    struct ChatResponse: Decodable {
        let choices: [Choice]?

        struct Choice: Decodable {
            let message: MessageContent?
            let delta: MessageContent?

            struct MessageContent: Decodable {
                let content: String?
            }
        }
    }

    // MARK: - Gateway Management

    func checkGateway() async -> Bool {
        guard let url = URL(string: "http://localhost:\(gatewayPort)/health") else { return false }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                isGatewayRunning = httpResponse.statusCode == 200
                return isGatewayRunning
            }
        } catch {
            isGatewayRunning = false
        }
        return false
    }

    func startGateway() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: findOpenClawCLI())
        process.arguments = ["gateway", "start"]
        process.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Wait a moment for gateway to start
        try await Task.sleep(nanoseconds: 2_000_000_000)

        isGatewayRunning = await checkGateway()
        if !isGatewayRunning {
            throw OpenClawError.gatewayStartFailed
        }
    }

    // MARK: - Chat

    func sendMessage(_ message: String, agentId: String = "openclaw:main", onChunk: @escaping @Sendable (String) -> Void) async throws {
        let url = URL(string: "http://localhost:\(gatewayPort)/v1/chat/completions")!

        let body = ChatRequest(
            model: agentId,
            messages: [ChatRequest.Message(role: "user", content: message)],
            stream: true
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw OpenClawError.requestFailed
        }

        // Parse SSE stream
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                let jsonStr = String(line.dropFirst(6))
                if jsonStr == "[DONE]" { break }

                if let data = jsonStr.data(using: .utf8),
                   let chunk = try? JSONDecoder().decode(ChatResponse.self, from: data),
                   let content = chunk.choices?.first?.delta?.content {
                    onChunk(content)
                }
            }
        }
    }

    // MARK: - Tools

    func invokeTool(name: String, parameters: [String: String]) async throws -> String {
        let url = URL(string: "http://localhost:\(gatewayPort)/tools/invoke")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["tool": name, "parameters": parameters]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Helpers

    private func findOpenClawCLI() -> String {
        let paths = [
            "/usr/local/bin/openclaw",
            "/opt/homebrew/bin/openclaw",
            "\(NSHomeDirectory())/.openclaw/bin/openclaw",
            "\(NSHomeDirectory())/.local/bin/openclaw"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) } ?? "openclaw"
    }

    enum OpenClawError: LocalizedError {
        case gatewayStartFailed
        case requestFailed
        case notInstalled

        var errorDescription: String? {
            switch self {
            case .gatewayStartFailed: return "Failed to start OpenClaw gateway"
            case .requestFailed: return "OpenClaw request failed"
            case .notInstalled: return "OpenClaw is not installed"
            }
        }
    }
}
