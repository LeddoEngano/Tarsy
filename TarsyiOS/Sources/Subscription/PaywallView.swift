import SwiftUI
import TarsyShared

struct PaywallView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var showError = false
    @State private var selectedPlan: Plan = .annual

    enum Plan {
        case monthly, annual
    }

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
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                // Icon
                VStack(spacing: 6) {
                    Image("TarsyLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
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

                Spacer().frame(height: 32)

                // Plan selector
                HStack(spacing: 12) {
                    planCard(
                        plan: .annual,
                        label: "Annual",
                        price: subscriptionManager.annualProduct?.displayPrice ?? "$119.99",
                        detail: "/year",
                        badge: "SAVE 33%"
                    )
                    planCard(
                        plan: .monthly,
                        label: "Monthly",
                        price: subscriptionManager.monthlyProduct?.displayPrice ?? "$14.99",
                        detail: "/month",
                        badge: nil
                    )
                }
                .padding(.horizontal, 24)

                // Effective monthly price for annual
                if selectedPlan == .annual {
                    Text("$9.99/month billed annually")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(.top, 8)
                } else {
                    Text("cancel anytime")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .padding(.top, 8)
                }

                // Auto-renewal disclosure
                Text("Subscription automatically renews. Manage or cancel anytime in Settings > App Store.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 12)

                Spacer().frame(height: 16)

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
                    Link("Terms", destination: URL(string: "https://www.tarsy.dev/terms")!)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                    Link("Privacy", destination: URL(string: "https://www.tarsy.dev/privacy")!)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                }
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text("Could not complete the purchase. Please try again.")
        }
    }

    private func planCard(plan: Plan, label: String, price: String, detail: String, badge: String?) -> some View {
        let isSelected = selectedPlan == plan

        return Button(action: { withAnimation(.easeInOut(duration: 0.2)) { selectedPlan = plan } }) {
            VStack(spacing: 6) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(TarsyTheme.backgroundPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(TarsyTheme.accentAmber)
                        .cornerRadius(4)
                } else {
                    Spacer().frame(height: 17)
                }

                Text(label)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(price)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundColor(isSelected ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isSelected ? TarsyTheme.backgroundSecondary : Color.clear)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? TarsyTheme.accentAmber : TarsyTheme.textSecondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
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

    private func purchase() {
        isPurchasing = true
        Task {
            let success = await subscriptionManager.purchase(annual: selectedPlan == .annual)
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

#if DEBUG
#Preview {
    PaywallView()
        .preferredColorScheme(.dark)
}
#endif
