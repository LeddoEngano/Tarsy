import Foundation
import Supabase

@MainActor
public class MachineService: ObservableObject {
    @Published public var machine: Machine?
    @Published public var isOnline = false

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

    public var tailscaleIP: String? {
        machine?.tailscaleIp
    }
}
