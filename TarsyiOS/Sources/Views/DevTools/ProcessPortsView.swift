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

        var isDevPort: Bool {
            let devPorts: Set<String> = ["3000", "8080", "5432", "4200", "8000", "5173", "4000", "8443", "5000"]
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

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
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
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Header
            HStack(spacing: 0) {
                Text("PROCESS")
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(spacing: 0) {
            Text(proc.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f%%", proc.cpu))
                .frame(width: 55, alignment: .trailing)
                .foregroundColor(proc.cpu > 50 ? TarsyTheme.accentTerracotta : TarsyTheme.textSecondary)
            Text(formatMB(proc.memoryMB))
                .frame(width: 60, alignment: .trailing)
            Text(proc.pid)
                .frame(width: 55, alignment: .trailing)
                .foregroundColor(TarsyTheme.textSecondary)
        }
        .font(TarsyTheme.font(size: 12))
        .foregroundColor(TarsyTheme.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(TarsyTheme.backgroundPrimary)
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

    @ViewBuilder
    private var portsContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 0) {
                Text("PORT")
                    .frame(width: 70, alignment: .leading)
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
            } else if ports.isEmpty {
                Spacer()
                Text("no listening ports")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(ports) { port in
                            portRow(port)
                        }
                    }
                }
            }
        }
    }

    private func portRow(_ port: PortItem) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(":\(port.port)")
                    .foregroundColor(TarsyTheme.textPrimary)
                if port.isDevPort {
                    Circle()
                        .fill(TarsyTheme.accentMoss)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 70, alignment: .leading)

            Text(port.processName)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(TarsyTheme.textPrimary)

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
                                pid: dict["pid"] ?? ""
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
        connectionManager.send(WSPacket(action: .processList))
        connectionManager.send(WSPacket(action: .portsList))
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
