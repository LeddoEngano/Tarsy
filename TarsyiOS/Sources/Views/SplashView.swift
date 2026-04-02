import SwiftUI

struct SplashView: View {
    @State private var showEyes = false
    @State private var showText = false
    @State private var showLoader = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 28) {
                TarsyEyes(size: 140)
                    .scaleEffect(showEyes ? 1 : 0.5)
                    .opacity(showEyes ? 1 : 0)

                VStack(spacing: 8) {
                    Text("tarsy")
                        .font(TarsyTheme.font(size: 48, weight: .bold))
                        .foregroundColor(TarsyTheme.accentAmber)

                    Text("remote agent controller")
                        .font(TarsyTheme.monoFontSmall)
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                .opacity(showText ? 1 : 0)
                .offset(y: showText ? 0 : 10)

                ProgressView()
                    .tint(TarsyTheme.accentAmber)
                    .opacity(showLoader ? 1 : 0)
            }
        }
        .onAppear {
            if reduceMotion {
                showEyes = true
                showText = true
                showLoader = true
            } else {
                withAnimation(.spring(duration: 0.5, bounce: 0.3)) {
                    showEyes = true
                }
                withAnimation(.easeOut(duration: 0.4).delay(0.35)) {
                    showText = true
                }
                withAnimation(.easeOut(duration: 0.3).delay(0.6)) {
                    showLoader = true
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    SplashView()
}
#endif
