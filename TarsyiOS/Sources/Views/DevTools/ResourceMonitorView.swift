import SwiftUI
import TarsyShared

struct ResourceMonitorView: View {
    let workspace: Workspace
    @EnvironmentObject var connectionManager: ConnectionManager
    @EnvironmentObject var machineService: MachineService

    @State private var cpuPercent: Double = 0
    @State private var memoryUsed: UInt64 = 0
    @State private var memoryTotal: UInt64 = 0
    @State private var diskUsed: UInt64 = 0
    @State private var diskTotal: UInt64 = 0
    @State private var isLoading = true

    private let pollTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Device header — makes it unambiguous that these metrics
            // are the Mac's, not the iPhone's. Users kept asking "is this
            // my phone's CPU?" without the label. Mirrors the dashboard
            // machine picker's icon+name+status-dot visual.
            machineHeader

            if isLoading {
                Spacer()
                ProgressView()
                    .tint(TarsyTheme.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        resourceCard(
                            title: "CPU",
                            value: String(format: "%.1f%%", cpuPercent),
                            percent: cpuPercent / 100.0,
                            color: cpuColor
                        )

                        resourceCard(
                            title: "Memory",
                            value: "\(formatBytes(memoryUsed)) / \(formatBytes(memoryTotal))",
                            percent: memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : 0,
                            color: memoryColor
                        )

                        resourceCard(
                            title: "Disk",
                            value: "\(formatBytes(diskUsed)) / \(formatBytes(diskTotal))",
                            percent: diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0,
                            color: diskColor
                        )
                    }
                    .padding(16)
                }
            }
        }
        .background(TarsyTheme.backgroundPrimary)
        .onAppear { setupListener(); requestResources() }
        .onDisappear { connectionManager.removeListener("resource-monitor") }
        .onReceive(pollTimer) { _ in requestResources() }
    }

    // MARK: - Device Header

    private var machineHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: machineService.selectedMachine?.deviceIcon ?? "desktopcomputer")
                .font(TarsyTheme.font(size: 16))
                .foregroundColor(TarsyTheme.accentAmber)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(machineService.selectedMachine?.name ?? "mac")
                    .font(TarsyTheme.font(size: 13, weight: .semibold))
                    .foregroundColor(TarsyTheme.textPrimary)
                    .lineLimit(1)
                Text("system resources")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)
            }

            Spacer()

            Circle()
                .fill(machineService.isOnline ? TarsyTheme.statusRunning : TarsyTheme.statusError)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TarsyTheme.backgroundSecondary)
    }

    // MARK: - Resource Card

    private func resourceCard(title: String, value: String, percent: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(TarsyTheme.font(size: 13, weight: .semibold))
                    .foregroundColor(TarsyTheme.textPrimary)
                Spacer()
                Text(value)
                    .font(TarsyTheme.font(size: 13))
                    .foregroundColor(TarsyTheme.textSecondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(TarsyTheme.backgroundTertiary)
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * min(percent, 1.0)), height: 8)
                        .animation(.easeInOut(duration: 0.5), value: percent)
                }
            }
            .frame(height: 8)

            Text(String(format: "%.0f%%", min(percent * 100, 100)))
                .font(TarsyTheme.font(size: 24, weight: .bold))
                .foregroundColor(TarsyTheme.textPrimary)
        }
        .padding(16)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(12)
    }

    // MARK: - Colors

    private var cpuColor: Color {
        cpuPercent > 80 ? TarsyTheme.accentTerracotta : cpuPercent > 50 ? TarsyTheme.statusStarting : TarsyTheme.accentMoss
    }

    private var memoryColor: Color {
        let percent = memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100 : 0
        return percent > 80 ? TarsyTheme.accentTerracotta : percent > 50 ? TarsyTheme.statusStarting : TarsyTheme.accentMoss
    }

    private var diskColor: Color {
        let percent = diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) * 100 : 0
        return percent > 80 ? TarsyTheme.accentTerracotta : percent > 50 ? TarsyTheme.statusStarting : TarsyTheme.accentMoss
    }

    // MARK: - Networking

    private func setupListener() {
        connectionManager.addListener("resource-monitor") { packet in
            guard packet.action == .systemResourcesResult else { return }
            DispatchQueue.main.async {
                isLoading = false
                cpuPercent = Double(packet.payload?["cpu_percent"] ?? "0") ?? 0
                memoryUsed = UInt64(packet.payload?["memory_used_bytes"] ?? "0") ?? 0
                memoryTotal = UInt64(packet.payload?["memory_total_bytes"] ?? "0") ?? 0
                diskUsed = UInt64(packet.payload?["disk_used_bytes"] ?? "0") ?? 0
                diskTotal = UInt64(packet.payload?["disk_total_bytes"] ?? "0") ?? 0
            }
        }
    }

    private func requestResources() {
        connectionManager.send(WSPacket(action: .systemResources))
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
