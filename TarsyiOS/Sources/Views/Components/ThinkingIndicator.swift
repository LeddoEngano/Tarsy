import SwiftUI

struct ThinkingIndicator: View {
    @State private var dotCount = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

struct AgentActivityView: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(TarsyTheme.accentAmber)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 1.0 : 0.4)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)

            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(TarsyTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { pulse = true }
    }
}
