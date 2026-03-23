import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("TARSY")
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .foregroundColor(TarsyTheme.accentAmber)

                ProgressView()
                    .tint(TarsyTheme.accentAmber)
            }
        }
    }
}
