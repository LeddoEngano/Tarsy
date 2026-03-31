import SwiftUI

struct SplashView: View {
    @State private var opacity = 0.0
    @State private var scale = 0.8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image("TarsyLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

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
            if reduceMotion {
                opacity = 1
                scale = 1
            } else {
                withAnimation(.easeOut(duration: 0.6)) {
                    opacity = 1
                    scale = 1
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
