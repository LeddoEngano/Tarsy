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
    /// Uses local IP only when iPhone is on the same subnet.
    /// Falls back to Tailscale for remote access.
    public var bestIP: String? {
        // Check if we're on the same local network as the Mac
        if let macLocalIP = localIP, isOnSameSubnet(as: macLocalIP) {
            print("[MachineService] bestIP: using local \(macLocalIP) (same subnet)")
            return macLocalIP
        }

        // Remote — use Tailscale
        if let tsIP = tailscaleIP {
            print("[MachineService] bestIP: using Tailscale \(tsIP) (remote)")
            return tsIP
        }

        // Last resort
        print("[MachineService] bestIP: no IP available")
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
