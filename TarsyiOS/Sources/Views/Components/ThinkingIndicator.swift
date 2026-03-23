import SwiftUI

struct ThinkingIndicator: View {
    @State private var dotCount = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 8) {
            // Animated dots
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(TarsyTheme.accentAmber)
                        .frame(width: 6, height: 6)
                        .opacity(dotCount > index ? 1.0 : 0.3)
                        .animation(.easeInOut(duration: 0.3), value: dotCount)
                }
            }

            Text("thinking...")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(TarsyTheme.textSecondary)
        }
        .padding(10)
        .background(TarsyTheme.backgroundSecondary)
        .cornerRadius(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                dotCount = (dotCount + 1) % 4
            }
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
}
