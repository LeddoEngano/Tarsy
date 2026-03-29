import Foundation
import SwiftUI

struct AppUpdate: Equatable {
    let version: String
    let downloadURL: URL
    let releaseNotes: String?
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var availableUpdate: AppUpdate?
    @Published var isChecking = false
    @Published private(set) var dismissedVersion: String {
        didSet { UserDefaults.standard.set(dismissedVersion, forKey: "dismissedUpdateVersion") }
    }

    private static let endpoint = URL(string: "https://www.tarsy.dev/api/latest-version")!
    private static let allowedDownloadHost = "www.tarsy.dev"
    private static let checkInterval: TimeInterval = 3600 // 1 hour
    private var timer: Timer?
    private var hasStarted = false

    init() {
        self.dismissedVersion = UserDefaults.standard.string(forKey: "dismissedUpdateVersion") ?? ""
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var shouldShowBanner: Bool {
        guard let update = availableUpdate else { return false }
        return update.version != dismissedVersion
    }

    func startPeriodicChecks() {
        guard !hasStarted else { return }
        hasStarted = true

        Task { await check() }

        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.check()
            }
        }
    }

    func dismiss() {
        if let update = availableUpdate {
            dismissedVersion = update.version
        }
    }

    /// Check for updates. When `resetDismissed` is true (manual check), previously
    /// dismissed versions will be shown again if still available.
    func check(resetDismissed: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        if resetDismissed {
            dismissedVersion = ""
        }

        do {
            var request = URLRequest(url: Self.endpoint)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let latestVersion = json["version"] as? String,
                  let downloadURLString = json["downloadURL"] as? String,
                  let downloadURL = URL(string: downloadURLString),
                  downloadURL.scheme == "https",
                  downloadURL.host == Self.allowedDownloadHost else {
                return
            }

            let releaseNotes = json["releaseNotes"] as? String

            if isNewerVersion(latestVersion, than: currentVersion) {
                availableUpdate = AppUpdate(
                    version: latestVersion,
                    downloadURL: downloadURL,
                    releaseNotes: releaseNotes
                )
            } else {
                availableUpdate = nil
            }
        } catch {
            // Silent failure — update checks should never disrupt the app
        }
    }

    /// Semantic version comparison: returns true if `latest` > `current`
    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        guard !latestParts.isEmpty, !currentParts.isEmpty else { return false }

        for i in 0..<max(latestParts.count, currentParts.count) {
            let l = i < latestParts.count ? latestParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if l > c { return true }
            if l < c { return false }
        }
        return false
    }
}
