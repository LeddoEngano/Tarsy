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
                .font(TarsyTheme.font(size: 12))
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
                .font(TarsyTheme.font(size: 11))
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

struct ActivityNarrationView: View {
    let lines: [String]
    @State private var isExpanded = false
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: pulse dot + latest line
            HStack(spacing: 8) {
                Circle()
                    .fill(TarsyTheme.accentAmber)
                    .frame(width: 6, height: 6)
                    .opacity(pulse ? 1.0 : 0.4)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)

                if let latest = lines.last {
                    Text(latest)
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                if lines.count > 1 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text("\(lines.count - 1) more")
                            .font(TarsyTheme.font(size: 9))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                    }
                }
            }

            // Expanded: previous lines
            if isExpanded && lines.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.dropLast().enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.4))
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TarsyTheme.backgroundSecondary.opacity(0.5))
        .cornerRadius(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { pulse = true }
    }
}

#if DEBUG
#Preview("Thinking Indicator") {
    VStack(spacing: 16) {
        ThinkingIndicator()
        AgentActivityView(text: "Reading file src/components/App.tsx")
        ActivityNarrationView(lines: [
            "I'm checking the landing page structure and first styles.",
            "The repo is a monorepo; I'm narrowing this to the web app.",
            "I found the landing page wrapper forcing a green background.",
        ])
    }
    .padding()
    .background(TarsyTheme.backgroundPrimary)
}
#endif
