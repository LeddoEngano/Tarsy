import Foundation
import StoreKit
import TarsyShared

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    static let proMonthlyProductId = "tarsy_pro_monthly"
    static let proAnnualProductId = "tarsy_pro_annual"
    static let allProductIds = [proMonthlyProductId, proAnnualProductId]
    static let maxFreeWorkspaces = 1

    @Published var isPro = false
    @Published var isLoading = true
    @Published var monthlyProduct: Product?
    @Published var annualProduct: Product?
    @Published var expirationDate: Date?

    /// Convenience: the monthly product (used by legacy callers)
    var product: Product? { monthlyProduct }

    var profileService: ProfileService?
    private var transactionListener: Task<Void, Never>?

    private init() {}

    func start() {
        transactionListener = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handle(transactionResult: result)
            }
        }

        Task {
            await loadProduct()
            await refreshStatus()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: Self.allProductIds)
            for p in products {
                switch p.id {
                case Self.proMonthlyProductId:
                    monthlyProduct = p
                case Self.proAnnualProductId:
                    annualProduct = p
                default:
                    break
                }
            }
        } catch {
        }
    }

    func refreshStatus() async {
        var foundActive = false

        for await result in Transaction.currentEntitlements {
            if let transaction = try? result.payloadValue,
               Self.allProductIds.contains(transaction.productID) {
                foundActive = true
                expirationDate = transaction.expirationDate
                break
            }
        }

        isPro = foundActive
        isLoading = false
        await syncWithProfile()
    }

    func purchase(annual: Bool = false) async -> Bool {
        let selectedProduct = annual ? annualProduct : monthlyProduct
        guard let selectedProduct else {
            return false
        }

        do {
            let result = try await selectedProduct.purchase()

            switch result {
            case .success(let verification):
                let transaction = try verification.payloadValue
                await transaction.finish()
                isPro = true
                expirationDate = transaction.expirationDate
                await syncWithProfile()
                await profileService?.sendBillingEmail(type: "subscription_active")
                return true

            case .userCancelled:
                return false

            case .pending:
                return false

            @unknown default:
                return false
            }
        } catch {
            return false
        }
    }

    func restore() async -> Bool {
        do {
            try await AppStore.sync()
            await refreshStatus()
            return isPro
        } catch {
            return false
        }
    }

    func canCreateWorkspace(currentCount: Int) -> Bool {
        if isPro { return true }
        return currentCount < Self.maxFreeWorkspaces
    }

    private func handle(transactionResult result: VerificationResult<Transaction>) async {
        guard let transaction = try? result.payloadValue else { return }

        let wasPro = isPro

        if Self.allProductIds.contains(transaction.productID) {
            if transaction.revocationDate != nil {
                isPro = false
                expirationDate = nil
            } else {
                isPro = true
                expirationDate = transaction.expirationDate
            }
        }

        await transaction.finish()
        await syncWithProfile()

        // Send billing emails on state transitions
        if !wasPro && isPro {
            await profileService?.sendBillingEmail(type: "subscription_renewed")
        } else if wasPro && !isPro {
            await profileService?.sendBillingEmail(type: "subscription_cancelled", endDate: expirationDate)
        }
    }

    /// Validates the latest transaction server-side via the verify-receipt edge function.
    /// The server determines subscription status — the client does not tell the server its own status.
    private func syncWithProfile() async {
        // Find the latest verified transaction to send to the server
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? result.payloadValue,
                  Self.allProductIds.contains(transaction.productID) else { continue }

            // Get the JWS representation for server-side validation
            let jwsRepresentation = result.jwsRepresentation
            await verifyOnServer(jwsRepresentation: jwsRepresentation)
            return
        }

        // No active entitlement — tell server with empty transaction
        await verifyOnServer(jwsRepresentation: "")
    }

    /// Send signed transaction to server for validation
    private func verifyOnServer(jwsRepresentation: String) async {
        do {
            let session = try await supabase.auth.session
            let url = URL(string: "\(TarsyConfig.supabaseURL.absoluteString)/functions/v1/verify-receipt")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "signedTransactionInfo": jwsRepresentation
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse

            if httpResponse?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let serverIsPro = json["isPro"] as? Bool ?? false
                let serverEndDate = (json["expirationDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

                isPro = serverIsPro
                expirationDate = serverEndDate
                profileService?.profile?.isPro = serverIsPro
            }
        } catch {
        }
    }

}
