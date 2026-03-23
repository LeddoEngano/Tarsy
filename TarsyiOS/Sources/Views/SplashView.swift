import SwiftUI

struct SplashView: View {
    @State private var opacity = 0.0
    @State private var scale = 0.8

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Eyes icon
                HStack(spacing: 8) {
                    Circle()
                        .fill(TarsyTheme.accentAmber)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .fill(TarsyTheme.backgroundPrimary)
                                .frame(width: 10, height: 10)
                                .offset(x: 2, y: -2)
                        )
                    Circle()
                        .fill(TarsyTheme.accentAmber)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .fill(TarsyTheme.backgroundPrimary)
                                .frame(width: 10, height: 10)
                                .offset(x: 2, y: -2)
                        )
                }

                Text("TARSY")
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundColor(TarsyTheme.accentAmber)

                Text("remote agent controller")
                    .font(TarsyTheme.monoFontSmall)
                    .foregroundColor(TarsyTheme.textSecondary)

                ProgressView()
                    .tint(TarsyTheme.accentAmber)
                    .padding(.top, 8)
            }
            .scaleEffect(scale)
            .opacity(opacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                opacity = 1
                scale = 1
            }
        }
    }
}
