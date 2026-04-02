import Foundation
import SwiftUI

struct AppUpdate: Equatable {
    let version: String
    let downloadURL: URL
    let releaseNotes: String?
}

enum UpdateState: Equatable {
    case idle
    case downloading(progress: Double)
    case installing
    case failed(String)
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published var availableUpdate: AppUpdate?
    @Published var isChecking = false
    @Published var updateState: UpdateState = .idle
    @Published private(set) var dismissedVersion: String {
        didSet { UserDefaults.standard.set(dismissedVersion, forKey: "dismissedUpdateVersion") }
    }

    /// Called before the app terminates during a self-update.
    /// Use this to gracefully shut down services (e.g., DaemonManager.stop()).
    var onWillTerminate: (() -> Void)?

    private static let endpoint = URL(string: "https://www.tarsy.dev/api/latest-version")!
    private static let allowedDownloadHost = "www.tarsy.dev"
    private static let checkInterval: TimeInterval = 3600 // 1 hour
    private var timer: Timer?
    private var hasStarted = false
    private var downloadDelegate: DownloadDelegate?

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

    // MARK: - Self-Update

    /// Downloads the DMG, mounts it, replaces the current app, and relaunches.
    func downloadAndInstall() async {
        guard let update = availableUpdate else { return }
        // Allow retry from failed state
        switch updateState {
        case .idle, .failed:
            break
        default:
            return
        }

        updateState = .downloading(progress: 0)

        // Track temp files for cleanup on failure
        var dmgURL: URL?
        var mountPoint: String?

        do {
            // 1. Verify we can write to the app's parent directory before doing anything
            let currentAppURL = Bundle.main.bundleURL
            let appParent = currentAppURL.deletingLastPathComponent().path
            guard FileManager.default.isWritableFile(atPath: appParent) else {
                updateState = .failed("No write permission to \(appParent). Try moving Tarsy to /Applications.")
                return
            }

            // 2. Download DMG to temp
            dmgURL = try await downloadDMG(from: update.downloadURL)

            // 3. Mount DMG (off main thread to avoid UI freeze)
            updateState = .installing
            mountPoint = try await runOffMain { try self.mountDMGSync(at: dmgURL!) }

            // 4. Find .app inside mounted DMG
            guard let appURL = try findApp(in: mountPoint!) else {
                updateState = .failed("Could not find Tarsy.app in the update")
                throw UpdateError.mountFailed
            }

            // 5. Verify code signature of the downloaded app
            let verified = try await runOffMain { self.verifyCodeSignature(at: appURL) }
            guard verified else {
                updateState = .failed("Update failed signature verification")
                throw UpdateError.signatureInvalid
            }

            // 6. Create updater script and run it
            //    The script handles: wait for quit → backup → replace → cleanup → relaunch
            try launchUpdaterScript(
                newAppURL: appURL,
                currentAppURL: currentAppURL,
                mountPoint: mountPoint!,
                dmgPath: dmgURL!.path
            )

            // 7. Gracefully stop services and quit — the script takes over from here
            onWillTerminate?()
            NSApplication.shared.terminate(nil)

        } catch {
            // Clean up temp files on any failure
            if let mp = mountPoint {
                try? await runOffMain { try self.detachDMGSync(mountPoint: mp) }
            }
            if let dmg = dmgURL {
                try? FileManager.default.removeItem(at: dmg)
            }
            if case .failed = updateState {
                // Already set a specific message
            } else {
                updateState = .failed(error.localizedDescription)
            }
        }
    }

    func resetUpdateState() {
        updateState = .idle
    }

    // MARK: - Private Helpers

    private func downloadDMG(from url: URL) async throws -> URL {
        // The download URL from the API points to /download/macos which redirects to the DMG.
        // We need to follow that redirect to get the actual DMG URL.
        let delegate = DownloadDelegate { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.updateState = .downloading(progress: progress)
            }
        }
        self.downloadDelegate = delegate

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        // Move to a named .dmg file (URLSession gives it no extension)
        let dmgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tarsy-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: tempURL, to: dmgURL)

        self.downloadDelegate = nil
        return dmgURL
    }

    /// Runs a throwing closure off the main actor to avoid blocking the UI.
    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try work()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous — must be called off main thread.
    private nonisolated func mountDMGSync(at dmgURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmgURL.path, "-nobrowse", "-noautoopen", "-plist"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw UpdateError.mountFailed
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw UpdateError.mountFailed
        }

        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String {
                return mountPoint
            }
        }

        throw UpdateError.mountFailed
    }

    /// Verifies the code signature of a .app bundle using codesign.
    private nonisolated func verifyCodeSignature(at appURL: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", appURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func findApp(in mountPoint: String) throws -> URL? {
        let mountURL = URL(fileURLWithPath: mountPoint)
        let contents = try FileManager.default.contentsOfDirectory(
            at: mountURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents.first { $0.pathExtension == "app" }
    }

    /// Synchronous — must be called off main thread.
    private nonisolated func detachDMGSync(mountPoint: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint, "-quiet"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
    }

    /// Launches a shell script that waits for the current app to quit,
    /// backs up the old app, replaces it with the new version, and relaunches.
    /// If the copy fails, it restores the backup so the user never loses the app.
    private func launchUpdaterScript(
        newAppURL: URL,
        currentAppURL: URL,
        mountPoint: String,
        dmgPath: String
    ) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let backupPath = currentAppURL.path + ".update-backup"

        let eCurrent = shellEscape(currentAppURL.path)
        let eNew = shellEscape(newAppURL.path)
        let eBackup = shellEscape(backupPath)
        let eMount = shellEscape(mountPoint)
        let eDmg = shellEscape(dmgPath)

        let script = """
        #!/bin/bash

        # Wait for the current app to quit
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.2
        done
        sleep 0.5

        # Backup the old app (move is atomic on same volume)
        if [ -d \(eCurrent) ]; then
            rm -rf \(eBackup)
            mv \(eCurrent) \(eBackup)
        fi

        # Copy the new app
        if cp -R \(eNew) \(eCurrent); then
            # Success — remove quarantine and clean up backup
            xattr -dr com.apple.quarantine \(eCurrent) 2>/dev/null || true
            rm -rf \(eBackup)
        else
            # Copy failed — restore backup
            if [ -d \(eBackup) ]; then
                mv \(eBackup) \(eCurrent)
            fi
        fi

        # Unmount DMG and clean up temp files
        /usr/bin/hdiutil detach \(eMount) -quiet 2>/dev/null || true
        rm -f \(eDmg) 2>/dev/null || true
        rm -f "$0" 2>/dev/null || true

        # Relaunch
        open \(eCurrent)
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarsy-updater-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

// MARK: - Download Delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async download call
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }
}

// MARK: - Errors

private enum UpdateError: LocalizedError {
    case downloadFailed
    case mountFailed
    case signatureInvalid

    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "Failed to download the update"
        case .mountFailed: return "Failed to open the update package"
        case .signatureInvalid: return "Update failed signature verification"
        }
    }
}
