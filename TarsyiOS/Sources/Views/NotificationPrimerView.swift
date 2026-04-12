import SwiftUI
import UserNotifications

struct NotificationPrimerView: View {
    let onComplete: () -> Void
    @State private var isRequesting = false

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Header
                VStack(spacing: 12) {
                    Image(systemName: "bell.badge")
                        .font(TarsyTheme.font(size: 48))
                        .foregroundColor(TarsyTheme.accentAmber)

                    Text("stay in the loop")
                        .font(TarsyTheme.font(size: 22, weight: .bold))
                        .foregroundColor(TarsyTheme.textPrimary)

                    Text("Get notified when your AI agent\nneeds input or finishes a task.")
                        .font(TarsyTheme.font(size: 13))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Benefits
                VStack(spacing: 16) {
                    benefitRow(
                        icon: "questionmark.circle",
                        text: "agent asks a question"
                    )
                    benefitRow(
                        icon: "checkmark.circle",
                        text: "task completed successfully"
                    )
                    benefitRow(
                        icon: "exclamationmark.triangle",
                        text: "something needs your attention"
                    )
                }
                .padding(20)
                .background(TarsyTheme.backgroundSecondary)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(TarsyTheme.backgroundTertiary, lineWidth: 1)
                )
                .padding(.horizontal, 20)

                Spacer()

                // Buttons
                VStack(spacing: 12) {
                    Button {
                        isRequesting = true
                        requestNotificationPermission()
                    } label: {
                        Text("enable notifications")
                            .font(TarsyTheme.font(size: 16, weight: .semibold))
                            .foregroundColor(TarsyTheme.backgroundPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TarsyTheme.accentAmber)
                            .cornerRadius(12)
                    }
                    .disabled(isRequesting)

                    Button {
                        onComplete()
                    } label: {
                        Text("maybe later")
                            .font(TarsyTheme.font(size: 13))
                            .foregroundColor(TarsyTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(TarsyTheme.font(size: 16))
                .foregroundColor(TarsyTheme.accentAmber)
                .frame(width: 24)

            Text(text)
                .font(TarsyTheme.font(size: 13))
                .foregroundColor(TarsyTheme.textPrimary)

            Spacer()
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                onComplete()
            }
        }
    }
}

#if DEBUG
#Preview {
    NotificationPrimerView {}
}
#endif
