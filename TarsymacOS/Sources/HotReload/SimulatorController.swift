import Foundation

struct SimulatorDevice: Codable, Sendable {
    let udid: String
    let name: String
    let runtime: String
    let state: String
    let isAvailable: Bool
}

enum SimulatorController {

    // MARK: - List Devices

    static func listDevices() async -> [SimulatorDevice] {
        guard let data = await run(["simctl", "list", "devices", "available", "-j"]) else { return [] }

        struct SimctlDevices: Decodable {
            let devices: [String: [SimctlDevice]]
            struct SimctlDevice: Decodable {
                let udid: String
                let name: String
                let state: String
                let isAvailable: Bool
            }
        }

        guard let parsed = try? JSONDecoder().decode(SimctlDevices.self, from: data) else { return [] }

        var result: [SimulatorDevice] = []
        for (runtime, devices) in parsed.devices {
            // Only include iPhone simulators on iOS runtimes
            let runtimeName = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
            guard runtimeName.contains("iOS") else { continue }
            for d in devices where d.isAvailable && d.name.contains("iPhone") {
                result.append(SimulatorDevice(
                    udid: d.udid, name: d.name,
                    runtime: runtimeName, state: d.state,
                    isAvailable: d.isAvailable
                ))
            }
        }
        return result.sorted { $0.runtime > $1.runtime }
    }

    // MARK: - Boot

    static func boot(udid: String) async throws {
        // Check if already booted
        if let data = await run(["simctl", "list", "devices", "booted", "-j"]),
           let str = String(data: data, encoding: .utf8), str.contains(udid) {
            return
        }
        guard await run(["simctl", "boot", udid]) != nil else {
            throw SimulatorError.bootFailed(udid)
        }
        // Wait for boot to settle
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    // MARK: - Install

    static func install(udid: String, appPath: String) async throws {
        guard await run(["simctl", "install", udid, appPath]) != nil else {
            throw SimulatorError.installFailed(appPath)
        }
    }

    // MARK: - Launch with Hot Reload

    static func launch(
        udid: String,
        bundleId: String,
        hotReloadDylibPath: String,
        socketPath: String
    ) async throws {
        // Terminate if already running (ignore errors)
        let _ = await run(["simctl", "terminate", udid, bundleId])

        // Launch with injection environment variables
        let env = ProcessInfo.processInfo.environment
        var launchEnv = env
        launchEnv["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = hotReloadDylibPath
        launchEnv["SIMCTL_CHILD_TARSY_HOT_RELOAD_SOCKET"] = socketPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "launch", udid, bundleId]
        process.environment = launchEnv

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SimulatorError.launchFailed(bundleId, output)
        }
    }

    // MARK: - Launch (simple, no injection)

    static func launchSimple(udid: String, bundleId: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "launch", udid, bundleId]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SimulatorError.launchFailed(bundleId, output)
        }
    }

    // MARK: - Terminate

    static func terminate(udid: String, bundleId: String) async {
        let _ = await run(["simctl", "terminate", udid, bundleId])
    }

    // MARK: - Get Booted Device

    static func bootedDeviceUDID() async -> String? {
        guard let data = await run(["simctl", "list", "devices", "booted", "-j"]) else { return nil }

        struct SimctlDevices: Decodable {
            let devices: [String: [BootedDevice]]
            struct BootedDevice: Decodable {
                let udid: String
                let state: String
            }
        }

        guard let parsed = try? JSONDecoder().decode(SimctlDevices.self, from: data) else { return nil }
        for (_, devices) in parsed.devices {
            if let booted = devices.first(where: { $0.state == "Booted" }) {
                return booted.udid
            }
        }
        return nil
    }

    // MARK: - Copy File to Simulator Tmp

    static func copyToSimulatorTmp(udid: String, filePath: String) async -> String? {
        // Simulator tmp is at ~/Library/Developer/CoreSimulator/Devices/<UDID>/data/tmp/
        let simTmp = NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices/\(udid)/data/tmp"

        let fm = FileManager.default
        if !fm.fileExists(atPath: simTmp) {
            try? fm.createDirectory(atPath: simTmp, withIntermediateDirectories: true)
        }

        let fileName = (filePath as NSString).lastPathComponent
        let destPath = simTmp + "/" + fileName

        try? fm.removeItem(atPath: destPath)
        do {
            try fm.copyItem(atPath: filePath, toPath: destPath)
            return destPath
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    @discardableResult
    private static func run(_ arguments: [String]) async -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return pipe.fileHandleForReading.readDataToEndOfFile()
            }
        } catch {}
        return nil
    }

    enum SimulatorError: LocalizedError {
        case bootFailed(String)
        case installFailed(String)
        case launchFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .bootFailed(let udid): return "Failed to boot simulator \(udid)"
            case .installFailed(let path): return "Failed to install app at \(path)"
            case .launchFailed(let id, let msg): return "Failed to launch \(id): \(msg)"
            }
        }
    }
}
