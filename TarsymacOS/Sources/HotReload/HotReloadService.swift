import Foundation
import TarsyShared

actor HotReloadService {

    // MARK: - Dependencies

    private let sendPacket: @Sendable (WSPacket, String) async -> Void
    private let logMessage: @Sendable (String) -> Void

    // MARK: - Sub-components

    private let buildRunner = XcodeBuildRunner()
    private var fileWatcher: FileWatcher?

    // MARK: - State

    private var activeSession: HotReloadSession?
    private var isReloading = false

    struct HotReloadSession {
        let workspacePath: String
        let projectFile: String
        let scheme: String
        let configuration: String
        let simulatorUDID: String
        let derivedDataPath: String
        let appBundleId: String
        let appBundlePath: String
        var clientId: String
        var reloadCount: Int = 0
    }

    // MARK: - Init

    init(
        sendPacket: @escaping @Sendable (WSPacket, String) async -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.sendPacket = sendPacket
        self.logMessage = log
    }

    // MARK: - Build & Run

    func buildAndRun(
        clientId: String,
        packetId: String,
        workspacePath: String,
        scheme: String,
        simulatorUDID: String,
        configuration: String
    ) async {
        log("Build & Run: path=\(workspacePath), scheme=\(scheme), sim=\(simulatorUDID)")

        // Stop any existing session
        await stopSession()

        // Auto-detect scheme if not provided
        var resolvedScheme = scheme
        if resolvedScheme.isEmpty {
            let schemes = await XcodeBuildRunner.listSchemes(projectPath: workspacePath)
            log("Auto-detected schemes: \(schemes)")
            guard let first = schemes.first else {
                await sendError(clientId: clientId, packetId: packetId, message: "No Xcode schemes found in \(workspacePath)")
                return
            }
            resolvedScheme = first
            log("Using scheme: \(resolvedScheme)")
            // Tell iOS which scheme was selected
            await sendPacket(
                WSPacket(action: .buildProgress, payload: ["output": "Using scheme: \(resolvedScheme)", "phase": "preparing", "percent": "0"]),
                clientId
            )
        }

        // Resolve simulator
        var targetUDID = simulatorUDID
        if targetUDID.isEmpty {
            if let booted = await SimulatorController.bootedDeviceUDID() {
                targetUDID = booted
                log("Using booted simulator: \(targetUDID)")
            } else {
                let devices = await SimulatorController.listDevices()
                guard let first = devices.first else {
                    await sendError(clientId: clientId, packetId: packetId, message: "No iOS Simulator available")
                    return
                }
                targetUDID = first.udid
                do {
                    await sendStatus(clientId: clientId, status: "booting", file: nil)
                    try await SimulatorController.boot(udid: targetUDID)
                } catch {
                    await sendError(clientId: clientId, packetId: packetId, message: "Failed to boot simulator: \(error.localizedDescription)")
                    return
                }
            }
        }

        await sendPacket(
            WSPacket(action: .simulatorStatus, payload: ["status": "booted", "simulatorUDID": targetUDID]),
            clientId
        )

        // Step 1: Build
        await sendPacket(
            WSPacket(action: .buildProgress, payload: ["output": "Building \(resolvedScheme)...", "phase": "preparing", "percent": "0"]),
            clientId
        )

        let result: BuildResult
        do {
            result = try await buildRunner.build(
                projectPath: workspacePath,
                scheme: resolvedScheme,
                configuration: configuration,
                simulatorUDID: targetUDID,
                onProgress: { [weak self] output, phase, percent in
                    guard let self else { return }
                    await self.sendPacket(
                        WSPacket(action: .buildProgress, payload: ["output": output, "phase": phase, "percent": "\(percent)"]),
                        clientId
                    )
                }
            )
        } catch {
            await sendError(clientId: clientId, packetId: packetId, message: error.localizedDescription)
            return
        }

        log("Build succeeded: \(result.appBundlePath), bundleId: \(result.appBundleId)")

        // Step 2: Install
        await sendPacket(
            WSPacket(action: .simulatorStatus, payload: ["status": "installing", "simulatorUDID": targetUDID]),
            clientId
        )

        do {
            try await SimulatorController.install(udid: targetUDID, appPath: result.appBundlePath)
        } catch {
            await sendError(clientId: clientId, packetId: packetId, message: "Install failed: \(error.localizedDescription)")
            return
        }

        // Step 3: Launch
        await sendPacket(
            WSPacket(action: .simulatorStatus, payload: ["status": "launching", "simulatorUDID": targetUDID, "appBundleId": result.appBundleId]),
            clientId
        )

        do {
            try await SimulatorController.launchSimple(udid: targetUDID, bundleId: result.appBundleId)
        } catch {
            await sendError(clientId: clientId, packetId: packetId, message: "Launch failed: \(error.localizedDescription)")
            return
        }

        // Step 4: Start file watcher for hot reload
        let watcher = FileWatcher { [weak self] changedFile in
            guard let self else { return }
            await self.handleFileChanged(changedFile)
        }
        fileWatcher = watcher
        await watcher.watch(directory: workspacePath)

        // Store session
        activeSession = HotReloadSession(
            workspacePath: workspacePath,
            projectFile: result.appBundlePath,
            scheme: resolvedScheme,
            configuration: configuration,
            simulatorUDID: targetUDID,
            derivedDataPath: result.derivedDataPath,
            appBundleId: result.appBundleId,
            appBundlePath: result.appBundlePath,
            clientId: clientId
        )

        log("Hot reload ready: watching \(workspacePath)")

        // Send build complete
        await sendPacket(
            WSPacket(action: .buildComplete, payload: ["appBundleId": result.appBundleId, "simulatorUDID": targetUDID], id: packetId),
            clientId
        )

        await sendStatus(clientId: clientId, status: "watching", file: nil)
    }

    // MARK: - Stop

    func stopSession() async {
        if let watcher = fileWatcher {
            await watcher.stop()
            fileWatcher = nil
        }
        if let session = activeSession {
            await SimulatorController.terminate(udid: session.simulatorUDID, bundleId: session.appBundleId)
        }
        activeSession = nil
        isReloading = false
    }

    // MARK: - File Change → Warm Relaunch

    private func handleFileChanged(_ filePath: String) async {
        guard let session = activeSession else { return }
        guard !isReloading else {
            log("Skipping \(filePath) — reload in progress")
            return
        }

        let fileName = (filePath as NSString).lastPathComponent
        log("File changed: \(fileName)")
        isReloading = true

        let startTime = CFAbsoluteTimeGetCurrent()

        await sendStatus(clientId: session.clientId, status: "compiling", file: fileName)

        // Step 1: Incremental build (xcodebuild reuses cached compilation)
        do {
            let result = try await buildRunner.build(
                projectPath: session.workspacePath,
                scheme: session.scheme,
                configuration: session.configuration,
                simulatorUDID: session.simulatorUDID,
                onProgress: { [weak self] output, phase, percent in
                    guard let self else { return }
                    // Only forward errors and key milestones during hot reload
                    if output.contains("error:") || phase == "complete" || phase == "error" {
                        await self.sendPacket(
                            WSPacket(action: .buildProgress, payload: ["output": output, "phase": phase, "percent": "\(percent)"]),
                            session.clientId
                        )
                    }
                }
            )

            guard result.success else {
                throw XcodeBuildRunner.BuildError.buildFailed("Incremental build failed")
            }

            // Step 2: Reinstall
            await sendStatus(clientId: session.clientId, status: "installing", file: fileName)
            try await SimulatorController.install(udid: session.simulatorUDID, appPath: result.appBundlePath)

            // Step 3: Terminate + Relaunch
            await sendStatus(clientId: session.clientId, status: "relaunching", file: fileName)
            await SimulatorController.terminate(udid: session.simulatorUDID, bundleId: session.appBundleId)
            try await SimulatorController.launchSimple(udid: session.simulatorUDID, bundleId: session.appBundleId)

            // Update session state
            activeSession?.reloadCount += 1

            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            log("Hot reload complete: \(fileName) in \(elapsed)ms")

            await sendPacket(
                WSPacket(action: .hotReloadInjection, payload: [
                    "file": fileName,
                    "durationMs": "\(elapsed)",
                    "classesChanged": "warm-relaunch"
                ]),
                session.clientId
            )

        } catch {
            log("Hot reload failed: \(error.localizedDescription)")
            await sendPacket(
                WSPacket(action: .hotReloadError, payload: [
                    "message": error.localizedDescription,
                    "file": fileName,
                    "recoverable": "true"
                ]),
                session.clientId
            )
        }

        isReloading = false
        await sendStatus(clientId: session.clientId, status: "watching", file: nil)
    }

    // MARK: - Helpers

    private func sendStatus(clientId: String, status: String, file: String?) async {
        var payload = ["status": status]
        if let file { payload["file"] = file }
        await sendPacket(WSPacket(action: .hotReloadStatus, payload: payload), clientId)
    }

    private func sendError(clientId: String, packetId: String, message: String) async {
        log("Error: \(message)")
        await sendPacket(
            WSPacket(action: .buildError, payload: ["message": message], id: packetId),
            clientId
        )
    }

    private func log(_ message: String) {
        logMessage("[HotReload] \(message)")
    }
}
