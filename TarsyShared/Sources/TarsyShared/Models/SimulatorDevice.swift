import Foundation

/// An iOS Simulator known to the macOS daemon. Emitted in the
/// `simulator:list_result` payload so iOS can show a picker before
/// kicking off Build & Run. Public because the iOS app decodes the
/// payload and renders the menu, while the macOS app populates it from
/// `simctl list devices`.
public struct SimulatorDevice: Codable, Sendable, Identifiable, Hashable {
    public let udid: String
    public let name: String
    public let runtime: String
    public let state: String
    public let isAvailable: Bool

    public var id: String { udid }

    /// True when `simctl` reports the device is currently booted.
    /// UI uses this to mark the simulator as the likely-default pick.
    public var isBooted: Bool { state.lowercased() == "booted" }

    /// Shortened runtime label, e.g. `"iOS 17.5"` instead of the raw
    /// `"iOS-17-5"` dashed format simctl emits.
    public var runtimeShortName: String {
        runtime.replacingOccurrences(of: "-", with: ".")
    }

    public init(udid: String, name: String, runtime: String, state: String, isAvailable: Bool) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.state = state
        self.isAvailable = isAvailable
    }
}
