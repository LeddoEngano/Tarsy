import Foundation
import Supabase

@MainActor
public class MachineService: ObservableObject {
    @Published public var machine: Machine?
    @Published public var machines: [Machine] = []
    @Published public var selectedMachineId: UUID?
    @Published public var isOnline = false

    public init() {}

    /// The currently selected machine (or first online, or first available)
    public var selectedMachine: Machine? {
        if let id = selectedMachineId {
            return machines.first { $0.id == id }
        }
        return machine
    }

    /// All machines that are currently online
    public var onlineMachines: [Machine] {
        machines.filter { $0.status == .online }
    }

    public func fetchMachine() async {
        do {
            let session = try await supabase.auth.session
            let allMachines: [Machine] = try await supabase
                .from("machines")
                .select()
                .eq("user_id", value: session.user.id.uuidString)
                .order("created_at")
                .execute()
                .value
            machines = allMachines

            // Select best machine: prefer currently selected, then first online, then first
            if let selectedId = selectedMachineId, let selected = allMachines.first(where: { $0.id == selectedId }) {
                machine = selected
            } else if let online = allMachines.first(where: { $0.status == .online }) {
                machine = online
                selectedMachineId = online.id
            } else {
                machine = allMachines.first
                selectedMachineId = machine?.id
            }
            isOnline = machine?.isRecentlyOnline ?? false
        } catch {
            #if DEBUG
            print("[MachineService] Fetch error: \(error)")
            #endif
        }
    }

    public func selectMachine(_ id: UUID) {
        selectedMachineId = id
        machine = machines.first { $0.id == id }
        isOnline = machine?.isRecentlyOnline ?? false
    }

    public var localIP: String? {
        machine?.localIp
    }

    /// Returns the best IP to connect to the Mac (local network).
    public var bestIP: String? {
        return localIP
    }

    /// Check if this device is on the same subnet as the given IP
    private func isOnSameSubnet(as macIP: String) -> Bool {
        let myIPs = getLocalIPAddresses()
        let macSubnet = subnetPrefix(of: macIP)

        for myIP in myIPs {
            if subnetPrefix(of: myIP) == macSubnet {
                return true
            }
        }
        return false
    }

    /// Extract subnet prefix (first 3 octets) — e.g. "192.168.0" from "192.168.0.248"
    private func subnetPrefix(of ip: String) -> String {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return ip }
        return parts[0...2].joined(separator: ".")
    }

    /// Get all local IP addresses of this device
    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return addresses }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // WiFi interfaces on iOS
                if name == "en0" || name == "en1" || name.hasPrefix("bridge") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if !ip.isEmpty {
                        addresses.append(ip)
                    }
                }
            }
        }
        return addresses
    }
}
