import SwiftUI
import TarsyShared

struct StatusBanner: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        if connectionManager.isReconnecting {
            banner(text: "reconnecting...", color: TarsyTheme.accentAmber, icon: "arrow.triangle.2.circlepath")
        } else if let error = connectionManager.errorMessage {
            banner(text: error, color: TarsyTheme.accentTerracotta, icon: "exclamationmark.triangle")
        }
    }

    @ViewBuilder
    private func banner(text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(TarsyTheme.monoFontSmall)
        }
        .foregroundColor(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct ConnectionIndicator: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            if connectionManager.isConnected {
                Text("\(Int(connectionManager.latency * 1000))ms")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
        }
    }

    private var statusColor: Color {
        if connectionManager.isConnected {
            return connectionManager.latency < 0.5 ? TarsyTheme.statusRunning : TarsyTheme.statusStarting
        }
        return connectionManager.isReconnecting ? TarsyTheme.statusStarting : TarsyTheme.statusError
    }
}
