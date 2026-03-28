import Foundation
import WebKit
import TarsyShared

class TarsyProxySchemeHandler: NSObject, WKURLSchemeHandler {
    let connectionManager: ConnectionManager
    private var pendingTasks: [String: any WKURLSchemeTask] = [:]
    private let listenerKey = "proxy-handler"

    init(connectionManager: ConnectionManager) {
        self.connectionManager = connectionManager
        super.init()
        setupListener()
    }

    private func setupListener() {
        connectionManager.addListener(listenerKey) { [weak self] packet in
            guard packet.action == .proxyResponse,
                  let requestId = packet.payload?["requestId"] else { return }

            Task { @MainActor in
                self?.handleProxyResponse(requestId: requestId, packet: packet)
            }
        }
    }

    func cleanup() {
        connectionManager.removeListener(listenerKey)
        pendingTasks.removeAll()
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let url = request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Validate host — only allow proxying to localhost/loopback to prevent SSRF
        let allowedHosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"]
        guard let host = url.host, allowedHosts.contains(host) else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Convert tarsy-http://localhost:3000/path → http://localhost:3000/path
        let realUrlString: String
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "http"
            realUrlString = components.url?.absoluteString ?? url.absoluteString.replacingOccurrences(of: "tarsy-http://", with: "http://")
        } else {
            realUrlString = url.absoluteString.replacingOccurrences(of: "tarsy-http://", with: "http://")
        }

        let requestId = UUID().uuidString
        pendingTasks[requestId] = urlSchemeTask

        // Timeout pending requests after 30 seconds to prevent memory leaks
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if let task = self?.pendingTasks.removeValue(forKey: requestId) {
                task.didFailWithError(URLError(.timedOut))
            }
        }

        // Build headers JSON
        var headers: [String: String] = [:]
        request.allHTTPHeaderFields?.forEach { headers[$0.key] = $0.value }
        let headersJson = (try? JSONSerialization.data(withJSONObject: headers))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        // Build body
        let bodyBase64 = request.httpBody?.base64EncodedString() ?? ""

        // Send via WebSocket
        connectionManager.send(WSPacket(
            action: .proxyRequest,
            payload: [
                "requestId": requestId,
                "url": realUrlString,
                "method": request.httpMethod ?? "GET",
                "headers": headersJson,
                "body": bodyBase64
            ]
        ))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Remove from pending
        pendingTasks = pendingTasks.filter { $0.value !== urlSchemeTask }
    }

    // MARK: - Response Handling

    private func handleProxyResponse(requestId: String, packet: WSPacket) {
        guard let task = pendingTasks.removeValue(forKey: requestId) else { return }

        if let error = packet.payload?["error"], !error.isEmpty {
            task.didFailWithError(URLError(.cannotConnectToHost))
            return
        }

        let statusCode = Int(packet.payload?["status"] ?? "0") ?? 0

        // Parse response headers
        var responseHeaders: [String: String] = [:]
        if let headersJson = packet.payload?["headers"],
           let headersData = headersJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: headersData) as? [String: String] {
            responseHeaders = parsed
        }

        // Rewrite Location header on redirects to keep tarsy-http scheme
        // so WKWebView doesn't try to follow redirects outside the custom scheme handler
        if (300...399).contains(statusCode), let location = responseHeaders["Location"] ?? responseHeaders["location"] {
            let rewritten = location
                .replacingOccurrences(of: "http://localhost", with: "tarsy-http://localhost")
                .replacingOccurrences(of: "http://127.0.0.1", with: "tarsy-http://127.0.0.1")
                .replacingOccurrences(of: "http://0.0.0.0", with: "tarsy-http://0.0.0.0")
                .replacingOccurrences(of: "http://[::1]", with: "tarsy-http://[::1]")
            responseHeaders["Location"] = rewritten
            responseHeaders.removeValue(forKey: "location")
        }

        // Decode body
        let bodyData: Data
        if let bodyBase64 = packet.payload?["body"], !bodyBase64.isEmpty {
            bodyData = Data(base64Encoded: bodyBase64) ?? Data()
        } else {
            bodyData = Data()
        }

        // Create response — use the original task URL to keep context
        // swiftlint:disable:next force_unwrapping — static URL literal, guaranteed valid
        let fallbackUrl = URL(string: "tarsy-http://proxy")!
        let responseUrl = task.request.url ?? fallbackUrl
        guard let response = HTTPURLResponse(
            url: responseUrl,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: responseHeaders
        ) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }

        task.didReceive(response)
        task.didReceive(bodyData)
        task.didFinish()
    }
}
