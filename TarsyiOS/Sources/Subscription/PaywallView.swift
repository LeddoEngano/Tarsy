import SwiftUI
import TarsyShared

struct PaywallView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var showError = false
    @State private var selectedPlan: Plan = .monthly

    enum Plan {
        case monthly, annual
    }

    /// Formats the annual price divided by 12 using the product's locale
    private var annualMonthlyEquivalent: String? {
        guard let product = subscriptionManager.annualProduct else { return nil }
        let monthly = product.price / 12
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = product.priceFormatStyle.locale
        return formatter.string(from: monthly as NSDecimalNumber)
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
                            .font(TarsyTheme.font(size: 16, weight: .medium))
                            .foregroundColor(TarsyTheme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(TarsyTheme.backgroundSecondary)
                            .cornerRadius(16)
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer().frame(height: 24)

                // Hero section
                VStack(spacing: 10) {
                    TarsyEyes(size: 56)

                    Text("TARSY PRO")
                        .font(TarsyTheme.font(size: 28, weight: .bold))
                        .foregroundColor(TarsyTheme.accentAmber)

                    Text("Unlock the full remote\ndevelopment experience")
                        .font(TarsyTheme.font(size: 14))
                        .foregroundColor(TarsyTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }

                Spacer()

                // Features grid — 2 columns
                VStack(spacing: 0) {
                    featureGridRow(
                        icon1: "square.stack.3d.up", text1: "Unlimited\nworkspaces",
                        icon2: "globe", text2: "Remote access\nvia relay"
                    )
                    featureGridRow(
                        icon1: "brain.head.profile", text1: "All AI\nengines",
                        icon2: "arrow.triangle.branch", text2: "Git checkpoints\n& rollback"
                    )
                    featureGridRow(
                        icon1: "folder", text1: "File\nexplorer",
                        icon2: "mic", text2: "Voice\nto text"
                    )
                }
                .padding(.horizontal, 24)

                Spacer()

                // Plan selector
                HStack(spacing: 20) {
                    planCard(
                        plan: .monthly,
                        label: "Monthly",
                        price: subscriptionManager.monthlyProduct?.displayPrice ?? "$14.99",
                        detail: "/month",
                        badge: nil
                    )
                    planCard(
                        plan: .annual,
                        label: "Annual",
                        price: subscriptionManager.annualProduct?.displayPrice ?? "$119.99",
                        detail: "/year",
                        badge: "SAVE 33%"
                    )
                }
                .padding(.horizontal, 24)

                // Contextual subtitle under plans
                Group {
                    if selectedPlan == .annual, let equiv = annualMonthlyEquivalent {
                        Text("\(equiv)/month billed annually")
                    } else {
                        Text("cancel anytime")
                    }
                }
                .font(TarsyTheme.font(size: 11))
                .foregroundColor(TarsyTheme.textSecondary)
                .padding(.top, 10)

                Spacer().frame(height: 20)

                // Subscribe button
                Button(action: { purchase() }) {
                    HStack(spacing: 8) {
                        if isPurchasing {
                            ProgressView()
                                .tint(TarsyTheme.backgroundPrimary)
                                .scaleEffect(0.8)
                        }
                        Text(isPurchasing ? "Processing..." : "Subscribe")
                            .font(TarsyTheme.font(size: 16, weight: .semibold))
                    }
                    .foregroundColor(TarsyTheme.backgroundPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(TarsyTheme.accentAmber)
                    .cornerRadius(14)
                }
                .disabled(isPurchasing || isRestoring)
                .padding(.horizontal, 24)

                Spacer().frame(height: 12)

                // Auto-renewal + restore
                Text("Subscription automatically renews. Manage or cancel anytime in Settings > App Store.")
                    .font(TarsyTheme.font(size: 10))
                    .foregroundColor(TarsyTheme.textSecondary.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer().frame(height: 12)

                // Restore + Legal
                HStack(spacing: 20) {
                    Button(action: { restore() }) {
                        Text(isRestoring ? "Restoring..." : "Restore")
                            .font(TarsyTheme.font(size: 11))
                            .foregroundColor(TarsyTheme.textSecondary.opacity(0.6))
                    }
                    .disabled(isPurchasing || isRestoring)

                    Link("Terms", destination: URL(string: "https://www.tarsy.dev/terms")!)
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.6))

                    Link("Privacy", destination: URL(string: "https://www.tarsy.dev/privacy")!)
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary.opacity(0.6))
                }
                .padding(.bottom, 20)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .alert("Something went wrong", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text("Could not complete the purchase. Please try again.")
        }
    }

    private func planCard(plan: Plan, label: String, price: String, detail: String, badge: String?) -> some View {
        let isSelected = selectedPlan == plan

        return Button(action: { withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { selectedPlan = plan } }) {
            VStack(spacing: 4) {
                Text(label)
                    .font(TarsyTheme.font(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(price)
                        .font(TarsyTheme.font(size: 20, weight: .bold))
                        .foregroundColor(isSelected ? TarsyTheme.textPrimary : TarsyTheme.textSecondary)
                    Text(detail)
                        .font(TarsyTheme.font(size: 11))
                        .foregroundColor(TarsyTheme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isSelected ? TarsyTheme.backgroundSecondary : Color.clear)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? TarsyTheme.accentAmber : TarsyTheme.textSecondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(TarsyTheme.font(size: 8, weight: .bold))
                        .foregroundColor(TarsyTheme.backgroundPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(TarsyTheme.accentAmber)
                        .cornerRadius(4)
                        .offset(x: -8, y: -8)
                }
            }
            .scaleEffect(isSelected ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private func featureGridRow(icon1: String, text1: String, icon2: String, text2: String) -> some View {
        HStack(spacing: 0) {
            featureCell(icon: icon1, text: text1)
            featureCell(icon: icon2, text: text2)
        }
    }

    private func featureCell(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(TarsyTheme.font(size: 14))
                .foregroundColor(TarsyTheme.accentAmber)
                .frame(width: 20)
            Text(text)
                .font(TarsyTheme.font(size: 12))
                .foregroundColor(TarsyTheme.textPrimary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
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
}
#endif
