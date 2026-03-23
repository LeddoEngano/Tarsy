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

    /// Prefer local IP when on same WiFi, fall back to Tailscale for remote.
    public var bestIP: String? {
        if let lip = localIP { return lip }
        return tailscaleIP
    }
}
