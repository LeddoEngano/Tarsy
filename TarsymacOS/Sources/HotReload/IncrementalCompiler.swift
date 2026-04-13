import Foundation

actor IncrementalCompiler {

    private var compileCount = 0

    // MARK: - Compile Single File

    /// Recompiles a single .swift file into a dynamically loadable .dylib.
    /// Returns the path to the signed dylib.
    func compile(
        file: String,
        command: CompileCommand,
        outputDir: String
    ) async throws -> String {
        compileCount += 1
        let index = compileCount

        let objectFile = outputDir + "/injection_\(index).o"
        let dylibFile = outputDir + "/injection_\(index).dylib"

        // Step 1: Compile .swift → .o using the original compiler flags
        try await compileToObject(file: file, command: command, outputPath: objectFile)

        // Step 2: Link .o → .dylib
        try await linkDylib(objectPath: objectFile, outputPath: dylibFile)

        // Step 3: Ad-hoc codesign
        try await codesign(path: dylibFile)

        // Clean up object file
        try? FileManager.default.removeItem(atPath: objectFile)

        return dylibFile
    }

    // MARK: - Step 1: Compile

    private func compileToObject(file: String, command: CompileCommand, outputPath: String) async throws {
        var args = command.arguments

        // Add the source file as -primary-file
        args.append("-primary-file")
        args.append(file)

        // Set output
        args.append("-o")
        args.append(outputPath)

        // Remove -frontend-parseable-output if present (causes issues with single-file compile)
        args.removeAll { $0 == "-frontend-parseable-output" }

        // Remove any -emit-module or -emit-module-path flags
        var i = 0
        while i < args.count {
            if args[i] == "-emit-module-path" || args[i] == "-emit-module-doc-path" ||
               args[i] == "-emit-module-source-info-path" || args[i] == "-emit-objc-header-path" {
                args.remove(at: i) // flag
                if i < args.count { args.remove(at: i) } // value
                continue
            }
            if args[i] == "-emit-module" || args[i] == "-emit-dependencies" ||
               args[i] == "-serialize-diagnostics" {
                args.remove(at: i)
                continue
            }
            i += 1
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.swiftcPath)
        process.arguments = args

        if !command.workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: command.workingDirectory)
        }

        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown compile error"
            throw CompileError.compileFailed(file: file, message: errMsg)
        }
    }

    // MARK: - Step 2: Link

    private func linkDylib(objectPath: String, outputPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "clang",
            "-arch", "arm64",
            "-target", "arm64-apple-ios17.0-simulator",
            "-isysroot", sdkPath(),
            "-dynamiclib",
            "-undefined", "dynamic_lookup",
            "-Xlinker", "-interposable",
            "-fobjc-arc",
            "-dead_strip",
            "-o", outputPath,
            objectPath
        ]

        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown link error"
            throw CompileError.linkFailed(message: errMsg)
        }
    }

    // MARK: - Step 3: Codesign

    private func codesign(path: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-fs", "-", path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        // Don't fail on codesign errors — Simulator often works without it
    }

    // MARK: - Helpers

    private func sdkPath() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "iphonesimulator", "--show-sdk-path"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
    }

    enum CompileError: LocalizedError {
        case compileFailed(file: String, message: String)
        case linkFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .compileFailed(let file, let msg):
                return "Compile failed for \((file as NSString).lastPathComponent): \(msg)"
            case .linkFailed(let msg):
                return "Link failed: \(msg)"
            }
        }
    }
}
