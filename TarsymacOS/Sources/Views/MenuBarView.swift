import SwiftUI
import TarsyShared

private enum Theme {
    static let bg = Color(hex: "131316")
    static let bgCard = Color(hex: "1c1c21")
    static let bgHover = Color(hex: "2a2a30")
    static let textPrimary = Color(hex: "e4e4e7")
    static let textSecondary = Color(hex: "71717a")
    static let textMuted = Color(hex: "52525b")
    static let amber = Color(hex: "ffffff")
    static let moss = Color(hex: "6bc77b")
    static let terracotta = Color(hex: "e5716a")
}

struct MenuBarView: View {
    @EnvironmentObject var authManager: AuthManager
    @EnvironmentObject var daemonManager: DaemonManager
    @EnvironmentObject var updateChecker: UpdateChecker
    @Environment(\.openWindow) var openWindow
    @State private var showUpToDateToast = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Text("tarsy")
                    .font(TarsyTheme.font(size: 14, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                Text("v\(updateChecker.currentVersion)")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(Theme.textMuted)

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(daemonManager.isRunning ? Theme.moss : Theme.terracotta)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .fill(daemonManager.isRunning ? Theme.moss : Theme.terracotta)
                                .frame(width: 7, height: 7)
                                .blur(radius: daemonManager.isRunning ? 4 : 0)
                                .opacity(daemonManager.isRunning ? 0.6 : 0)
                        )

                    Text(daemonManager.isRunning ? "online" : "offline")
                        .font(TarsyTheme.font(size: 10, weight: .medium))
                        .foregroundColor(daemonManager.isRunning ? Theme.moss : Theme.terracotta)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            // Update banner
            if let update = updateChecker.availableUpdate, updateChecker.shouldShowBanner {
                updateBanner(update)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Divider().overlay(Theme.bgHover)

            // Menu items
            VStack(spacing: 2) {
                if !authManager.isAuthenticated {
                    menuItem(icon: "person.crop.circle", label: "Sign In", color: Theme.amber) {
                        openWindow(id: "onboarding")
                    }
                }

                menuItem(icon: "gear", label: "Setup") {
                    openWindow(id: "onboarding")
                }

                SettingsLink {
                    menuItemLabel(icon: "slider.horizontal.3", label: "Settings")
                }
                .buttonStyle(.plain)
                .pointerOnHover()
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                })

                checkForUpdatesItem

                if authManager.isAuthenticated {
                    Divider().overlay(Theme.bgHover).padding(.vertical, 4)

                    menuItem(
                        icon: "rectangle.portrait.and.arrow.right",
                        label: "Sign Out",
                        color: Theme.textMuted
                    ) {
                        Task {
                            daemonManager.stop()
                            await authManager.signOut()
                        }
                    }
                }
            }
            .padding(.vertical, 6)

            Divider().overlay(Theme.bgHover)

            // Quit
            menuItem(icon: "power", label: "Quit Tarsy", color: Theme.terracotta) {
                daemonManager.stop()
                NSApplication.shared.terminate(nil)
            }
            .padding(.vertical, 6)
        }
        .frame(width: 260)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            if showUpToDateToast {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(Theme.moss)
                    Text("You're up to date")
                        .font(TarsyTheme.font(size: 11, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.bgHover)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.moss.opacity(0.3), lineWidth: 1)
                        )
                )
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showUpToDateToast)
        .task {
            if authManager.isAuthenticated {
                await daemonManager.start()
            }
        }
    }

    // MARK: - Components

    private var checkForUpdatesItem: some View {
        Button {
            Task {
                await updateChecker.check(resetDismissed: true)
                if updateChecker.availableUpdate == nil {
                    showUpToDateToast = true
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    showUpToDateToast = false
                }
            }
        } label: {
            HStack(spacing: 10) {
                if updateChecker.isChecking {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .frame(width: 16, alignment: .center)
                }

                Text("Check for Updates")
                    .font(TarsyTheme.font(size: 12))
                    .foregroundColor(Theme.textPrimary)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuItemButtonStyle())
        .pointerOnHover()
        .disabled(updateChecker.isChecking)
    }

    private func menuItem(
        icon: String,
        label: String,
        color: Color = Theme.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            menuItemLabel(icon: icon, label: label, color: color)
        }
        .buttonStyle(MenuItemButtonStyle())
        .pointerOnHover()
    }

    private func menuItemLabel(
        icon: String,
        label: String,
        color: Color = Theme.textSecondary
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(TarsyTheme.font(size: 11))
                .foregroundColor(color)
                .frame(width: 16, alignment: .center)

            Text(label)
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(Theme.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func updateBanner(_ update: AppUpdate) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(Theme.amber)
                    .font(TarsyTheme.font(size: 14))

                VStack(alignment: .leading, spacing: 1) {
                    Text("v\(update.version) available")
                        .font(TarsyTheme.font(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)

                    if let notes = update.releaseNotes {
                        Text(notes)
                            .font(TarsyTheme.font(size: 10))
                            .foregroundColor(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Button {
                    updateChecker.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(TarsyTheme.font(size: 8, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .pointerOnHover()
            }

            Button {
                NSWorkspace.shared.open(update.downloadURL)
            } label: {
                Text("Download")
                    .font(TarsyTheme.font(size: 11, weight: .medium))
                    .foregroundColor(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.amber)
                    )
            }
            .buttonStyle(.plain)
            .pointerOnHover()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.bgCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.amber.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Button Style

private struct MenuItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? Theme.bgHover : Color.clear)
                    .padding(.horizontal, 8)
            )
    }
}

#if DEBUG
#Preview("Menu Bar") {
    MenuBarView()
        .environmentObject(AuthManager())
        .environmentObject(DaemonManager())
        .environmentObject(UpdateChecker())
}
#endif
