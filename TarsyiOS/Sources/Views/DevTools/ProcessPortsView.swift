import SwiftUI
import TarsyShared

struct ProcessPortsView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager

    @State private var selectedTab: Tab = .processes
    @State private var processes: [ProcessItem] = []
    @State private var ports: [PortItem] = []
    @State private var searchText = ""
    @State private var sortKey: SortKey = .cpu
    @State private var sortAscending = false
    @State private var isLoading = true
    @State private var killTarget: KillTarget? = nil
    @State private var workspaceOnly = false

    private let pollTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    enum Tab: String, CaseIterable {
        case processes, ports
    }

    enum SortKey: String, CaseIterable {
        case name, cpu, memory
    }

    struct ProcessItem: Identifiable {
        let id: String // pid
        let name: String
        let pid: String
        let cpu: Double
        let memoryMB: Double
    }

    struct PortItem: Identifiable {
        var id: String { "\(port)-\(pid)" }
        let port: String
        let processName: String
        let pid: String
        /// TCP socket state (LISTEN / CLOSE_WAIT / TIME_WAIT / …) when
        /// reported by the macOS daemon. Shown next to the port so the
        /// user knows whether it's an active listener or an orphan
        /// socket blocking rebinding.
        let state: String

        var isDevPort: Bool {
            let devPorts: Set<String> = ["3000", "8080", "5432", "4200", "8000", "5173", "4000", "8443", "5000", "8081", "19000", "19001"]
            return devPorts.contains(port)
        }
    }

    enum KillTarget: Identifiable {
        case process(ProcessItem)
        case port(PortItem)

        var id: String {
            switch self {
            case .process(let p): return "proc-\(p.pid)"
            case .port(let p): return "port-\(p.pid)"
            }
        }

        var pid: String {
            switch self {
            case .process(let p): return p.pid
            case .port(let p): return p.pid
            }
        }

        var displayName: String {
            switch self {
            case .process(let p): return "\(p.name) (PID \(p.pid))"
            case .port(let p): return "\(p.processName) on :\(p.port) (PID \(p.pid))"
            }
        }
    }

    // MARK: - Tarsy Process Detection

    /// Known process names associated with Tarsy workspaces
    private static let tarsyProcessNames: Set<String> = [
        "claude", "claude-code", "node", "npm", "npx", "next-server",
        "vite", "tsx", "ts-node", "bun", "deno",
        "gemini", "codex", "aider", "python3", "python",
        "swift", "xcodebuild", "swiftc",
        "cargo", "rustc",
        "go", "air",
        "ruby", "rails", "puma",
        "java", "gradle", "mvn",
        "php", "artisan", "composer",
    ]

    private func isTarsyProcess(_ name: String) -> Bool {
        let lower = name.lowercased()
        return Self.tarsyProcessNames.contains(lower)
            || lower.contains("claude")
            || lower.contains("next-server")
            || lower.contains("webpack")
            || lower.contains("vite")
            || lower.contains("expo")
    }

    private func isTarsyPort(_ port: PortItem) -> Bool {
        return isTarsyProcess(port.processName) || port.isDevPort
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        // Reset the search when switching tabs so a port
                        // filter ("8081") doesn't carry over into the
                        // processes tab and hide everything — the
                        // searchText state is shared across tabs.
                        if selectedTab != tab { searchText = "" }
                        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(TarsyTheme.font(size: 12, weight: .medium))
                            .foregroundColor(selectedTab == tab ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(selectedTab == tab ? TarsyTheme.backgroundTertiary : Color.clear)
                            .cornerRadius(6)
                    }
                }
            }
            .padding(4)
            .background(TarsyTheme.backgroundSecondary)
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Workspace filter toggle
            HStack(spacing: 6) {
                Toggle("", isOn: $workspaceOnly)
                    .labelsHidden()
                    .tint(TarsyTheme.accentMoss)
                    .scaleEffect(0.8)
                Text("workspace only")
                    .font(TarsyTheme.font(size: 11))
                    .foregroundColor(workspaceOnly ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .onChange(of: workspaceOnly) { _, _ in
                isLoading = true
                requestData()
            }

            if selectedTab == .processes {
                processesContent
            } else {
                portsContent
            }
        }
        .background(TarsyTheme.backgroundPrimary)
        .onAppear { setupListener(); requestData() }
        .onDisappear { connectionManager.removeListener("process-ports") }
        .onReceive(pollTimer) { _ in requestData() }
        .alert(item: $killTarget) { target in
            Alert(
                title: Text("Kill Process"),
                message: Text("Terminate \(target.displayName)?"),
                primaryButton: .destructive(Text("Kill")) { killProcess(pid: target.pid) },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - Processes Tab

    private var filteredProcesses: [ProcessItem] {
        var result = processes
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortKey {
        case .name: result.sort { sortAscending ? $0.name < $1.name : $0.name > $1.name }
        case .cpu: result.sort { sortAscending ? $0.cpu < $1.cpu : $0.cpu > $1.cpu }
        case .memory: result.sort { sortAscending ? $0.memoryMB < $1.memoryMB : $0.memoryMB > $1.memoryMB }
        }
        return result
    }

    @ViewBuilder
    private var processesContent: some View {
        VStack(spacing: 0) {
            // Search + sort
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(TarsyTheme.textSecondary)
                        .font(.system(size: 12))
                    TextField("filter processes", text: $searchText)
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(8)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(8)

                Menu {
                    ForEach(SortKey.allCases, id: \.self) { key in
                        Button {
                            if sortKey == key { sortAscending.toggle() }
                            else { sortKey = key; sortAscending = false }
                        } label: {
                            HStack {
                                Text(key.rawValue)
                                if sortKey == key {
                                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(8)
                        .background(TarsyTheme.backgroundSecondary)
                        .cornerRadius(8)
                }

                Button {
                    isLoading = true
                    requestData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(8)
                        .background(TarsyTheme.backgroundSecondary)
                        .cornerRadius(8)
                }
                .accessibilityLabel("Refresh processes")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Header
            HStack(spacing: 0) {
                Text("PROCESS")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 24) // account for icon column
                Text("CPU")
                    .frame(width: 55, alignment: .trailing)
                Text("MEM")
                    .frame(width: 60, alignment: .trailing)
                Text("PID")
                    .frame(width: 55, alignment: .trailing)
            }
            .font(TarsyTheme.font(size: 10, weight: .semibold))
            .foregroundColor(TarsyTheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider().background(TarsyTheme.backgroundTertiary)

            if isLoading {
                Spacer()
                ProgressView().tint(TarsyTheme.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredProcesses) { proc in
                            processRow(proc)
                        }
                    }
                }
            }
        }
    }

    private func processRow(_ proc: ProcessItem) -> some View {
        let isTarsy = isTarsyProcess(proc.name)
        let accentColor = isTarsy ? Color.white : TarsyTheme.textPrimary

        return HStack(spacing: 0) {
            // Tarsy indicator
            if isTarsy {
                TarsyEyes(size: 18, animated: false)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Workspace process")
            } else {
                Color.clear.frame(width: 20, height: 20)
            }

            Text(proc.name)
                .lineLimit(1)
                .foregroundColor(accentColor)
                .fontWeight(isTarsy ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)

            Text(String(format: "%.1f%%", proc.cpu))
                .frame(width: 55, alignment: .trailing)
                .foregroundColor(proc.cpu > 50 ? TarsyTheme.accentTerracotta : TarsyTheme.textSecondary)
            Text(formatMB(proc.memoryMB))
                .frame(width: 60, alignment: .trailing)
                .foregroundColor(TarsyTheme.textSecondary)
            Text(proc.pid)
                .frame(width: 55, alignment: .trailing)
                .foregroundColor(TarsyTheme.textSecondary)
        }
        .font(TarsyTheme.font(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isTarsy ? TarsyTheme.backgroundSecondary : TarsyTheme.backgroundPrimary)
        .contextMenu {
            Button(role: .destructive) {
                killTarget = .process(proc)
            } label: {
                Label("Kill Process", systemImage: "xmark.circle")
            }
            Button {
                UIPasteboard.general.string = proc.pid
            } label: {
                Label("Copy PID", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Ports Tab

    /// Filters ports by `searchText` matching either the port number or
    /// the process name (case-insensitive on the process; exact substring
    /// on the port so `"80"` matches both `:80` and `:8080`).
    private var filteredPorts: [PortItem] {
        guard !searchText.isEmpty else { return ports }
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        return ports.filter {
            $0.port.contains(needle) ||
            $0.processName.localizedCaseInsensitiveContains(needle)
        }
    }

    @ViewBuilder
    private var portsContent: some View {
        VStack(spacing: 0) {
            // Search + refresh row
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(TarsyTheme.textSecondary)
                        .font(.system(size: 12))
                    TextField("filter ports (e.g. 8081, metro)", text: $searchText)
                        .font(TarsyTheme.font(size: 12))
                        .foregroundColor(TarsyTheme.textPrimary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.asciiCapable)
                }
                .padding(8)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(8)

                Button {
                    isLoading = true
                    requestData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(8)
                        .background(TarsyTheme.backgroundSecondary)
                        .cornerRadius(8)
                }
                .accessibilityLabel("Refresh ports")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Header
            HStack(spacing: 0) {
                Text("PORT")
                    .frame(width: 70, alignment: .leading)
                    .padding(.leading, 24) // account for icon column
                Text("PROCESS")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("PID")
                    .frame(width: 60, alignment: .trailing)
                Spacer().frame(width: 40)
            }
            .font(TarsyTheme.font(size: 10, weight: .semibold))
            .foregroundColor(TarsyTheme.textSecondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider().background(TarsyTheme.backgroundTertiary)

            if isLoading {
                Spacer()
                ProgressView().tint(TarsyTheme.textSecondary)
                Spacer()
            } else if filteredPorts.isEmpty {
                Spacer()
                Text(searchText.isEmpty ? "no listening ports" : "no ports match '\(searchText)'")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredPorts) { port in
                            portRow(port)
                        }
                    }
                }
            }
        }
    }

    private func portRow(_ port: PortItem) -> some View {
        let isTarsy = isTarsyPort(port)
        let accentColor = isTarsy ? Color.white : TarsyTheme.textPrimary

        return HStack(spacing: 0) {
            // Tarsy indicator
            if isTarsy {
                TarsyEyes(size: 18, animated: false)
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Workspace port")
            } else {
                Color.clear.frame(width: 20, height: 20)
            }

            HStack(spacing: 4) {
                Text(":\(port.port)")
                    .foregroundColor(accentColor)
                    .fontWeight(isTarsy ? .semibold : .regular)
                if port.isDevPort {
                    Circle()
                        .fill(TarsyTheme.accentMoss)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(port.processName)
                    .lineLimit(1)
                    .foregroundColor(accentColor)
                    .fontWeight(isTarsy ? .semibold : .regular)
                // Show state when present AND non-LISTEN (orphan/zombie
                // sockets are the ones users care to see — a healthy
                // LISTEN socket doesn't need a state label).
                if !port.state.isEmpty && port.state != "LISTEN" {
                    Text(port.state)
                        .font(TarsyTheme.font(size: 9, weight: .semibold))
                        .foregroundColor(TarsyTheme.accentTerracotta)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(port.pid)
                .frame(width: 60, alignment: .trailing)
                .foregroundColor(TarsyTheme.textSecondary)

            Button {
                killTarget = .port(port)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(TarsyTheme.accentTerracotta.opacity(0.8))
                    .font(.system(size: 14))
            }
            .frame(width: 40)
        }
        .font(TarsyTheme.font(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isTarsy ? TarsyTheme.backgroundSecondary : TarsyTheme.backgroundPrimary)
        .contextMenu {
            Button(role: .destructive) {
                killTarget = .port(port)
            } label: {
                Label("Kill Process", systemImage: "xmark.circle")
            }
            Button {
                UIPasteboard.general.string = port.port
            } label: {
                Label("Copy Port", systemImage: "doc.on.doc")
            }
        }
    }

    // MARK: - Networking

    private func setupListener() {
        connectionManager.addListener("process-ports") { packet in
            DispatchQueue.main.async {
                switch packet.action {
                case .processListResult:
                    isLoading = false
                    if let json = packet.payload?["processes"],
                       let data = json.data(using: .utf8),
                       let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                        processes = list.map { dict in
                            ProcessItem(
                                id: dict["pid"] ?? UUID().uuidString,
                                name: dict["name"] ?? "",
                                pid: dict["pid"] ?? "",
                                cpu: Double(dict["cpu"] ?? "0") ?? 0,
                                memoryMB: Double(dict["memory_mb"] ?? "0") ?? 0
                            )
                        }
                    }
                case .portsListResult:
                    if let json = packet.payload?["ports"],
                       let data = json.data(using: .utf8),
                       let list = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                        ports = list.map { dict in
                            PortItem(
                                port: dict["port"] ?? "",
                                processName: dict["process_name"] ?? "",
                                pid: dict["pid"] ?? "",
                                state: dict["state"] ?? ""
                            )
                        }
                    }
                case .processKillResult:
                    // Refresh after kill
                    requestData()
                default:
                    break
                }
            }
        }
    }

    private func requestData() {
        let payload: [String: String]? = workspaceOnly ? ["path": workspace.effectivePath] : nil
        connectionManager.send(WSPacket(action: .processList, payload: payload))
        connectionManager.send(WSPacket(action: .portsList, payload: payload))
    }

    private func killProcess(pid: String) {
        connectionManager.send(WSPacket(action: .processKill, payload: ["pid": pid]))
    }

    // MARK: - Formatting

    private func formatMB(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
