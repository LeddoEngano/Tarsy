import SwiftUI

struct SimulatorDeviceInfo: Codable, Identifiable {
    let udid: String
    let name: String
    let runtime: String
    let state: String
    let isAvailable: Bool

    var id: String { udid }
}

struct HotReloadStatusBadge: View {
    let status: String
    let injectionCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            Text(statusText)
                .font(TarsyTheme.font(size: 10))
                .foregroundColor(TarsyTheme.textSecondary)

            if injectionCount > 0 {
                Text("(\(injectionCount))")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(4)
    }

    private var statusColor: Color {
        switch status {
        case "watching": return Color(red: 0.4, green: 0.8, blue: 0.4) // green
        case "compiling": return Color(red: 0.9, green: 0.7, blue: 0.2) // yellow
        case "injecting": return Color(red: 0.3, green: 0.6, blue: 0.9) // blue
        case "error", "rebuild_needed": return Color(red: 0.8, green: 0.3, blue: 0.3) // red
        default: return TarsyTheme.textSecondary
        }
    }

    private var statusText: String {
        switch status {
        case "watching": return "hot reload"
        case "compiling": return "compiling..."
        case "injecting": return "injecting..."
        case "error": return "error"
        case "rebuild_needed": return "rebuild needed"
        default: return "idle"
        }
    }
}
