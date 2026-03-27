import SwiftUI

struct VoiceTodoOverlay: View {
    @ObservedObject var todoManager: VoiceTodoManager

    var body: some View {
        if todoManager.items.isEmpty {
            EmptyView()
        } else if todoManager.isMinimized {
            minimizedBadge
        } else {
            expandedCard
        }
    }

    // MARK: - Minimized Badge

    private var minimizedBadge: some View {
        Button {
            todoManager.expand()
        } label: {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.1))
                    .frame(width: 32, height: 32)

                if todoManager.hasQuestionItems {
                    Image(systemName: "questionmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(TarsyTheme.accentAmber)
                } else if todoManager.hasWorkingItems, let tool = todoManager.items.last(where: { $0.status == .working })?.currentTool {
                    ShakingIcon(systemName: VoiceTodoManager.iconForTool(tool), size: 14, color: TarsyTheme.accentAmber)
                } else if todoManager.hasWorkingItems {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(TarsyTheme.accentAmber)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(TarsyTheme.accentMoss)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if todoManager.workingCount > 1 {
                Text("\(todoManager.workingCount)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 14, height: 14)
                    .background(TarsyTheme.accentAmber)
                    .clipShape(Circle())
                    .offset(x: 4, y: -4)
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Expanded Card

    private var expandedCard: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("tasks")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Button { todoManager.minimize() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // Items
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(todoManager.items.reversed()) { item in
                        HStack(spacing: 8) {
                            if item.status == .question {
                                Image(systemName: "questionmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(TarsyTheme.accentAmber)
                                    .frame(width: 16, height: 16)
                            } else if item.status == .working {
                                if let tool = item.currentTool {
                                    ShakingIcon(systemName: VoiceTodoManager.iconForTool(tool), size: 12, color: TarsyTheme.accentAmber)
                                        .frame(width: 16, height: 16)
                                } else {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .tint(TarsyTheme.accentAmber)
                                        .frame(width: 16, height: 16)
                                }
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(TarsyTheme.accentMoss)
                                    .frame(width: 16, height: 16)
                            }

                            Text(item.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.06))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 180)
        }
        .frame(maxWidth: 260)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.4), radius: 12)
        .transition(.scale(scale: 0.8, anchor: .bottomTrailing).combined(with: .opacity))
    }

}

// MARK: - Shaking Icon

private struct ShakingIcon: View {
    let systemName: String
    let size: CGFloat
    let color: Color
    @State private var shaking = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size))
            .foregroundColor(color)
            .offset(x: shaking ? -1.5 : 0)
            .animation(.linear(duration: 0.06).repeatCount(5, autoreverses: true), value: shaking)
            .onAppear { startShakeLoop() }
    }

    private func startShakeLoop() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            shaking = false
            DispatchQueue.main.async {
                shaking = true
            }
        }
    }
}
