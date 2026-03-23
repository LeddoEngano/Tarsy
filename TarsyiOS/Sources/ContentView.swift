import SwiftUI
import TarsyShared

struct ContentView: View {
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        Group {
            if authManager.isLoading {
                SplashView()
            } else if authManager.isAuthenticated {
                DashboardView()
            } else {
                LoginView()
            }
        }
        .preferredColorScheme(.dark)
    }
}
