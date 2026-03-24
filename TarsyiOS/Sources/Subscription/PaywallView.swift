import SwiftUI
import TarsyShared

struct PaywallView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var showError = false

    var body: some View {
        ZStack {
            TarsyTheme.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Close button
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(TarsyTheme.backgroundSecondary)
                            .cornerRadius(16)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                // Icon
                VStack(spacing: 6) {
                    HStack(spacing: 4) {
                        eyeIcon(size: 20)
                        eyeIcon(size: 20)
                    }
                    Text("TARSY PRO")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.accentAmber)
                }

                Spacer().frame(height: 32)

                // Features list
                VStack(alignment: .leading, spacing: 16) {
                    featureRow(icon: "square.stack.3d.up", text: "Unlimited workspaces")
                    featureRow(icon: "globe", text: "Remote access via relay")
                    featureRow(icon: "brain.head.profile", text: "All AI engines")
                    featureRow(icon: "arrow.triangle.branch", text: "Git checkpoints & rollback")
                    featureRow(icon: "folder", text: "File explorer")
                    featureRow(icon: "mic", text: "Voice to text")
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 40)

                // Price
                VStack(spacing: 4) {
                    if let product = subscriptionManager.product {
                        Text(product.displayPrice + "/month")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(TarsyTheme.textPrimary)
                    } else {
                        Text("$9/month")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundColor(TarsyTheme.textPrimary)
                    }
                    Text("cancel anytime")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                }

                Spacer().frame(height: 24)

                // Subscribe button
                Button(action: { purchase() }) {
                    HStack {
                        if isPurchasing {
                            ProgressView()
                                .tint(TarsyTheme.backgroundPrimary)
                                .scaleEffect(0.8)
                        }
                        Text(isPurchasing ? "Processing..." : "Subscribe")
                            .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(TarsyTheme.accentAmber)
                    .cornerRadius(14)
                }
                .disabled(isPurchasing || isRestoring)
                .padding(.horizontal, 24)

                // Restore
                Button(action: { restore() }) {
                    Text(isRestoring ? "Restoring..." : "Restore purchase")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
                .disabled(isPurchasing || isRestoring)
                .padding(.top, 12)

                Spacer().frame(height: 16)

                // Legal
                HStack(spacing: 16) {
                    Link("Terms", destination: URL(string: "https://tarsy.app/terms")!)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                    Link("Privacy", destination: URL(string: "https://tarsy.app/privacy")!)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                }
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text("Could not complete the purchase. Please try again.")
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(TarsyTheme.accentAmber)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(TarsyTheme.textPrimary)
        }
    }

    @ViewBuilder
    private func eyeIcon(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(TarsyTheme.accentAmber)
                .frame(width: size, height: size)
            Circle()
                .fill(TarsyTheme.backgroundPrimary)
                .frame(width: size * 0.45, height: size * 0.45)
                .offset(x: size * 0.05, y: -size * 0.05)
            Circle()
                .fill(.white.opacity(0.5))
                .frame(width: size * 0.15, height: size * 0.15)
                .offset(x: size * 0.1, y: -size * 0.1)
        }
    }

    private func purchase() {
        isPurchasing = true
        Task {
            let success = await subscriptionManager.purchase()
            isPurchasing = false
            if success {
                dismiss()
            } else {
                showError = true
            }
        }
    }

    private func restore() {
        isRestoring = true
        Task {
            let success = await subscriptionManager.restore()
            isRestoring = false
            if success {
                dismiss()
            }
        }
    }
}
