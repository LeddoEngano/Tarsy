import Foundation
import CoreServices

actor FileWatcher {

    private var stream: FSEventStreamRef?
    private let callback: @Sendable (String) async -> Void
    private let debounceInterval: TimeInterval = 0.3
    private var pendingFiles: Set<String> = []
    private var debounceTask: Task<Void, Never>?

    private static let excludedDirs: Set<String> = [
        "DerivedData", ".build", "Pods", ".git", "node_modules",
        "Build", "Index.noindex", "SourcePackages"
    ]

    init(onChange: @escaping @Sendable (String) async -> Void) {
        self.callback = onChange
    }

    func watch(directory: String) {
        stop()

        let paths = [directory] as CFArray
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        var context = FSEventStreamContext(
            version: 0, info: ctx,
            retain: nil, release: nil, copyDescription: nil
        )

        guard let newStream = FSEventStreamCreate(
            nil,
            fileWatcherCallback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2, // latency
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        FSEventStreamStart(newStream)
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingFiles.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    // Called from the C callback
    nonisolated func handleEvent(path: String, flags: FSEventStreamEventFlags) {
        // Only .swift files
        guard path.hasSuffix(".swift") else { return }

        // Must be a file modification or rename (not directory)
        let isModified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0
        let isRenamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
        let isCreated = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
        guard isModified || isRenamed || isCreated else { return }

        // Exclude build artifacts and caches
        let components = path.split(separator: "/")
        for excluded in Self.excludedDirs {
            if components.contains(Substring(excluded)) { return }
        }

        Task { await self.enqueue(path: path) }
    }

    private func enqueue(path: String) {
        pendingFiles.insert(path)

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }

            let files = pendingFiles
            pendingFiles.removeAll()

            for file in files {
                await callback(file)
            }
        }
    }
}

// C callback bridging
private func fileWatcherCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()

    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    for i in 0..<numEvents {
        let cfPath = CFArrayGetValueAtIndex(paths, i)
        let path = Unmanaged<CFString>.fromOpaque(cfPath!).takeUnretainedValue() as String
        watcher.handleEvent(path: path, flags: eventFlags[i])
    }
}
