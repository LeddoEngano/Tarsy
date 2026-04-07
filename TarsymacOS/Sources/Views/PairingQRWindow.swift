import SwiftUI
import TarsyShared

private enum Theme {
    static let bg = Color(hex: "131316")
}

struct PairingQRWindow: View {
    @EnvironmentObject var daemonManager: DaemonManager

    var body: some View {
        PairingQRCodeView(machineId: daemonManager.machineId, onPaired: {
            NSApplication.shared.keyWindow?.close()
        })
            .padding(24)
            .frame(width: 280)
            .background(Theme.bg)
    }
}

#if DEBUG
#Preview("Pairing QR") {
    PairingQRWindow()
        .environmentObject(DaemonManager())
}
#endif
