import SwiftUI
import TarsyShared

struct APIClientView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var method: HTTPMethod = .get
    @State private var url = ""
    @State private var headers: [HeaderEntry] = [HeaderEntry(key: "Content-Type", value: "application/json")]
    @State private var requestBody = ""
    @State private var isLoading = false

    // Response
    @State private var response: APIResponse? = nil
    @State private var showHistory = false
    @State private var history: [HistoryEntry] = []

    enum HTTPMethod: String, CaseIterable {
        case get = "GET"
        case post = "POST"
    }

    struct HeaderEntry: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    struct APIResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: String
        let durationMs: Int
        let error: String?
    }

    struct HistoryEntry: Codable, Identifiable {
        let id: String
        let method: String
        let url: String
        let statusCode: Int
        let timestamp: Date
        let headersJson: String?
        let body: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Method + URL
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(HTTPMethod.allCases, id: \.self) { m in
                                Button(m.rawValue) { method = m }
                            }
                        } label: {
                            Text(method.rawValue)
                                .font(TarsyTheme.font(size: 12, weight: .bold))
                                .foregroundColor(method == .get ? TarsyTheme.accentMoss : TarsyTheme.statusStarting)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(TarsyTheme.backgroundSecondary)
                                .cornerRadius(8)
                        }

                        TextField("http://localhost:3000/api/...", text: $url)
                            .font(TarsyTheme.font(size: 12))
                            .foregroundColor(TarsyTheme.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .padding(8)
                            .background(TarsyTheme.backgroundSecondary)
                            .cornerRadius(8)
                    }

                    // Headers
                    headerSection

                    // Body (POST only)
                    if method == .post {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Body")
                                .font(TarsyTheme.font(size: 10, weight: .semibold))
                                .foregroundColor(TarsyTheme.textSecondary)

                            TextEditor(text: $requestBody)
                                .font(TarsyTheme.font(size: 12))
                                .foregroundColor(TarsyTheme.textPrimary)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 80, maxHeight: 120)
                                .padding(8)
                                .background(TarsyTheme.backgroundSecondary)
                                .cornerRadius(8)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }

                    // Send + History buttons
                    HStack(spacing: 8) {
                        Button {
                            sendRequest()
                        } label: {
                            HStack(spacing: 6) {
                                if isLoading {
                                    ProgressView().tint(TarsyTheme.backgroundPrimary)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text("Send")
                            }
                            .font(TarsyTheme.font(size: 12, weight: .semibold))
                            .foregroundColor(TarsyTheme.backgroundPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(url.isEmpty ? TarsyTheme.textSecondary : TarsyTheme.textPrimary)
                            .cornerRadius(8)
                        }
                        .disabled(url.isEmpty || isLoading)

                        Button {
                            showHistory.toggle()
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 14))
                                .foregroundColor(TarsyTheme.textSecondary)
                                .padding(10)
                                .background(TarsyTheme.backgroundSecondary)
                                .cornerRadius(8)
                        }
                    }

                    // Response
                    if let response = response {
                        responseSection(response)
                    }
                }
                .padding(16)
            }
        }
        .background(TarsyTheme.backgroundPrimary)
        .onAppear { setupListener(); loadHistory() }
        .onDisappear { connectionManager.removeListener("api-client") }
        .sheet(isPresented: $showHistory) {
            historySheet
        }
    }

    // MARK: - Headers

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Headers")
                    .font(TarsyTheme.font(size: 10, weight: .semibold))
                    .foregroundColor(TarsyTheme.textSecondary)
                Spacer()
                Button {
                    headers.append(HeaderEntry(key: "", value: ""))
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }

            ForEach(headers.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("key", text: $headers[i].key)
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(maxWidth: .infinity)

                    Text(":")
                        .foregroundColor(TarsyTheme.textSecondary)

                    TextField("value", text: $headers[i].value)
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(maxWidth: .infinity)

                    Button {
                        headers.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                            .foregroundColor(TarsyTheme.accentTerracotta.opacity(0.7))
                    }
                }
                .padding(6)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Response

    private func responseSection(_ resp: APIResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(TarsyTheme.backgroundTertiary)

            if let error = resp.error {
                Text(error)
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(TarsyTheme.accentTerracotta)
            } else {
                // Status + duration
                HStack(spacing: 8) {
                    Text("\(resp.statusCode)")
                        .font(TarsyTheme.font(size: 14, weight: .bold))
                        .foregroundColor(statusColor(resp.statusCode))
                    Text(HTTPURLResponse.localizedString(forStatusCode: resp.statusCode))
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary)
                    Spacer()
                    Text("\(resp.durationMs)ms")
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                // Response headers (collapsible)
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(resp.headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack(spacing: 4) {
                                Text(key)
                                    .foregroundColor(TarsyTheme.textSecondary)
                                Text(value)
                                    .foregroundColor(TarsyTheme.textPrimary)
                                    .lineLimit(1)
                            }
                            .font(TarsyTheme.font(size: 10))
                        }
                    }
                } label: {
                    Text("Headers (\(resp.headers.count))")
                        .font(TarsyTheme.font(size: 11, weight: .medium))
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                // Body
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Body")
                            .font(TarsyTheme.font(size: 10, weight: .semibold))
                            .foregroundColor(TarsyTheme.textSecondary)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = resp.body
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundColor(TarsyTheme.textSecondary)
                        }
                    }
                    ScrollView {
                        Text(prettyJSON(resp.body))
                            .font(TarsyTheme.font(size: 11))
                            .foregroundColor(TarsyTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 300)
                    .padding(8)
                    .background(TarsyTheme.backgroundTertiary)
                    .cornerRadius(8)
                }
            }
        }
    }

    // MARK: - History Sheet

    private var historySheet: some View {
        NavigationStack {
            List {
                if history.isEmpty {
                    Text("no recent requests")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                        .listRowBackground(TarsyTheme.backgroundSecondary)
                } else {
                    ForEach(history) { entry in
                        Button {
                            loadFromHistory(entry)
                            showHistory = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(entry.method)
                                    .font(TarsyTheme.font(size: 10, weight: .bold))
                                    .foregroundColor(entry.method == "GET" ? TarsyTheme.accentMoss : TarsyTheme.statusStarting)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.url)
                                        .font(TarsyTheme.font(size: 11))
                                        .foregroundColor(TarsyTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(entry.timestamp, style: .relative)
                                        .font(TarsyTheme.font(size: 9))
                                        .foregroundColor(TarsyTheme.textSecondary)
                                }
                                Spacer()
                                Text("\(entry.statusCode)")
                                    .font(TarsyTheme.font(size: 11, weight: .semibold))
                                    .foregroundColor(statusColor(entry.statusCode))
                            }
                        }
                        .listRowBackground(TarsyTheme.backgroundSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(TarsyTheme.backgroundPrimary)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showHistory = false }
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textPrimary)
                }
            }
        }
    }

    // MARK: - Networking

    private func setupListener() {
        connectionManager.addListener("api-client") { packet in
            guard packet.action == .httpResponse else { return }
            DispatchQueue.main.async {
                isLoading = false
                if let error = packet.payload?["error"] {
                    response = APIResponse(statusCode: 0, headers: [:], body: "", durationMs: 0, error: error)
                    return
                }

                let statusCode = Int(packet.payload?["status_code"] ?? "0") ?? 0
                let durationMs = Int(packet.payload?["duration_ms"] ?? "0") ?? 0
                let bodyStr = packet.payload?["body"] ?? ""
                var respHeaders: [String: String] = [:]
                if let hJson = packet.payload?["headers"],
                   let hData = hJson.data(using: .utf8),
                   let h = try? JSONSerialization.jsonObject(with: hData) as? [String: String] {
                    respHeaders = h
                }

                response = APIResponse(statusCode: statusCode, headers: respHeaders, body: bodyStr, durationMs: durationMs, error: nil)

                // Save to history
                let entry = HistoryEntry(
                    id: UUID().uuidString,
                    method: method.rawValue,
                    url: url,
                    statusCode: statusCode,
                    timestamp: Date(),
                    headersJson: nil,
                    body: method == .post ? requestBody : nil
                )
                history.insert(entry, at: 0)
                if history.count > 50 { history = Array(history.prefix(50)) }
                saveHistory()
            }
        }
    }

    private func sendRequest() {
        guard !url.isEmpty else { return }
        isLoading = true
        response = nil

        var headersDict: [String: String] = [:]
        for h in headers where !h.key.isEmpty {
            headersDict[h.key] = h.value
        }
        let headersJson = (try? JSONSerialization.data(withJSONObject: headersDict)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        var payload: [String: String] = [
            "method": method.rawValue,
            "url": url,
            "headers": headersJson,
        ]
        if method == .post && !requestBody.isEmpty {
            payload["body"] = requestBody
        }

        connectionManager.send(WSPacket(action: .httpRequest, payload: payload))
    }

    // MARK: - History Persistence

    private let historyKey = "devtools_api_history"

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              var entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        // Prune entries older than 24h
        let cutoff = Date().addingTimeInterval(-86400)
        entries = entries.filter { $0.timestamp > cutoff }
        history = entries
    }

    private func saveHistory() {
        // Prune before saving
        let cutoff = Date().addingTimeInterval(-86400)
        let filtered = history.filter { $0.timestamp > cutoff }
        if let data = try? JSONEncoder().encode(filtered) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    private func loadFromHistory(_ entry: HistoryEntry) {
        method = HTTPMethod(rawValue: entry.method) ?? .get
        url = entry.url
        if let b = entry.body { requestBody = b }
    }

    // MARK: - Helpers

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return TarsyTheme.accentMoss
        case 400..<500: return TarsyTheme.statusStarting
        case 500..<600: return TarsyTheme.accentTerracotta
        default: return TarsyTheme.textSecondary
        }
    }

    private func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8) else {
            return text
        }
        return str
    }
}
