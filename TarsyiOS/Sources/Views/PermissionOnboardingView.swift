import SwiftUI
import TarsyShared

struct PermissionOnboardingView: View {
    @EnvironmentObject var profileService: ProfileService
    @State private var config = AgentPermissionConfig()
    @State private var globalMode: AgentPermissionConfig.PermissionMode = .dangerous
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Header
                VStack(spacing: 12) {
                    Image(systemName: "shield.checkered")
                        .font(.system(size: 48))
                        .foregroundColor(TarsyTheme.accentAmber)

                    Text("agent permissions")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.textPrimary)

                    Text("Choose how AI agents interact with your code.\nYou can change this anytime in settings.")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Mode selection
                VStack(spacing: 12) {
                    modeCard(
                        mode: .dangerous,
                        title: "Auto Mode",
                        description: "Agents execute freely without asking for permission. Faster, but less control.",
                        icon: "bolt.fill",
                        isSelected: globalMode == .dangerous
                    )

                    modeCard(
                        mode: .safe,
                        title: "Safe Mode",
                        description: "Agents ask before each action. Slower, but you approve every change.",
                        icon: "lock.shield.fill",
                        isSelected: globalMode == .safe
                    )
                }
                .padding(.horizontal, 20)

                Spacer()

                // Continue button
                Button {
                    // Apply global mode to all engines
                    for engine in AIEngineType.allCases where engine != .custom {
                        config.setMode(globalMode, for: engine)
                    }
                    config.save()
                    Task {
                        var perms: [String: String] = [:]
                        for engine in AIEngineType.allCases where engine != .custom {
                            perms[engine.rawValue] = globalMode.rawValue
                        }
                        await profileService.updateAgentPermissions(perms)
                        await profileService.markOnboarded()
                    }
                    onComplete()
                } label: {
                    Text("continue")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(TarsyTheme.backgroundPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(TarsyTheme.accentAmber)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
    }

    private func modeCard(
        mode: AgentPermissionConfig.PermissionMode,
        title: String,
        description: String,
        icon: String,
        isSelected: Bool
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                globalMode = mode
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? TarsyTheme.accentAmber : TarsyTheme.textSecondary)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(TarsyTheme.textPrimary)

                    Text(description)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(isSelected ? TarsyTheme.accentAmber : TarsyTheme.textSecondary.opacity(0.4))
            }
            .padding(16)
            .background(TarsyTheme.backgroundSecondary)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? TarsyTheme.accentAmber : TarsyTheme.backgroundTertiary, lineWidth: isSelected ? 1.5 : 1)
            )
        }
    }
}
