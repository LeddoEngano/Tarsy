import Foundation

public enum TarsyConfig {
    public static let supabaseURL = URL(string: "https://xtblbghhlkroskzljqcl.supabase.co")!
    public static let supabaseAnonKey = "sb_publishable_J_nOhA2NRFGtz7W1vd_ZaA_2St0Emzs"
    public static let websocketPort: UInt16 = 8642
    public static let relayURL = "wss://tarsy-relay.fly.dev/ws"
    public static let relayDevURL = "ws://localhost:8080/ws" // for local development
}
