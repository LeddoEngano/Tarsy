import Foundation

public enum TarsyConfig {
    public static let supabaseURL: URL = {
        let urlString = Bundle.main.infoDictionary?["TARSY_SUPABASE_URL"] as? String ?? ""
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            fatalError("TARSY_SUPABASE_URL not set. Copy Tarsy.xcconfig.template to Tarsy.xcconfig and fill in your values.")
        }
        return url
    }()

    public static let supabaseAnonKey: String = {
        let key = Bundle.main.infoDictionary?["TARSY_SUPABASE_ANON_KEY"] as? String ?? ""
        guard !key.isEmpty else {
            fatalError("TARSY_SUPABASE_ANON_KEY not set. Copy Tarsy.xcconfig.template to Tarsy.xcconfig and fill in your values.")
        }
        return key
    }()

    public static let websocketPort: UInt16 = 8642

    public static let relayURL: String = {
        Bundle.main.infoDictionary?["TARSY_RELAY_URL"] as? String ?? "wss://tarsy-relay.fly.dev/ws"
    }()

    public static let relayDevURL = "ws://localhost:8080/ws"
}
