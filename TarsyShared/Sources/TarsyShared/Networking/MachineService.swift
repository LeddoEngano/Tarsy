import Foundation
import Supabase

@MainActor
public class MachineService: ObservableObject {
    @Published public var machine: Machine?
    @Published public var isOnline = false
    @Published public var hasTailscale = false

    public init() {}

    public func fetchMachine() async {
        do {
            let session = try await supabase.auth.session
            let machines: [Machine] = try await supabase
                .from("machines")
                .select()
                .eq("user_id", value: session.user.id.uuidString)
                .execute()
                .value
            machine = machines.first
            isOnline = machine?.status == .online
        } catch {
            print("[MachineService] Fetch error: \(error)")
        }
    }

    public func setTailscaleInstalled(_ installed: Bool) {
        hasTailscale = installed
    }

    public var tailscaleIP: String? {
        machine?.tailscaleIp
    }

    public var localIP: String? {
        machine?.localIp
    }

    /// Returns the best IP to connect to the Mac.
    /// Prefers local IP (same WiFi, lower latency), falls back to Tailscale IP.
    public var bestIP: String? {
        // If Tailscale is installed on iPhone, prefer Tailscale (works from anywhere)
        if hasTailscale, let tsIP = tailscaleIP {
            return tsIP
        }
        // Otherwise use local IP (same WiFi only)
        if let lip = localIP {
            return lip
        }
        // Last resort: tailscale IP even without the app (won't work but shows intent)
        return tailscaleIP
    }
}
