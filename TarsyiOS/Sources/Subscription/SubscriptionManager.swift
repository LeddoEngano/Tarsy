import Foundation
import StoreKit
import TarsyShared

@MainActor
class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    static let proProductId = "tarsy_pro_monthly"
    static let maxFreeWorkspaces = 1

    @Published var isPro = false
    @Published var isLoading = true
    @Published var product: Product?
    @Published var expirationDate: Date?

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
            let products = try await Product.products(for: [Self.proProductId])
            product = products.first
        } catch {
            print("[Subscription] Error loading product: \(error)")
        }
    }

    func refreshStatus() async {
        var foundActive = false

        for await result in Transaction.currentEntitlements {
            if let transaction = try? result.payloadValue,
               transaction.productID == Self.proProductId {
                foundActive = true
                expirationDate = transaction.expirationDate
                break
            }
        }

        isPro = foundActive
        isLoading = false
        print("[Subscription] Pro: \(isPro), expires: \(expirationDate?.description ?? "n/a")")
        await syncWithProfile()
    }

    func purchase() async -> Bool {
        guard let product else {
            print("[Subscription] No product available")
            return false
        }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try verification.payloadValue
                await transaction.finish()
                isPro = true
                expirationDate = transaction.expirationDate
                return true

            case .userCancelled:
                return false

            case .pending:
                return false

            @unknown default:
                return false
            }
        } catch {
            print("[Subscription] Purchase error: \(error)")
            return false
        }
    }

    func restore() async -> Bool {
        do {
            try await AppStore.sync()
            await refreshStatus()
            return isPro
        } catch {
            print("[Subscription] Restore error: \(error)")
            return false
        }
    }

    func canCreateWorkspace(currentCount: Int) -> Bool {
        if isPro { return true }
        return currentCount < Self.maxFreeWorkspaces
    }

    private func handle(transactionResult result: VerificationResult<Transaction>) async {
        guard let transaction = try? result.payloadValue else { return }

        if transaction.productID == Self.proProductId {
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
    }

    private func syncWithProfile() async {
        let status: String
        if isPro {
            status = "active"
        } else if expirationDate != nil {
            status = "cancelled"
        } else {
            status = "inactive"
        }
        await profileService?.updateSubscription(isPro: isPro, status: status, endDate: expirationDate)
    }
}
