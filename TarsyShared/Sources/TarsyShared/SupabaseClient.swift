import Foundation
import Supabase

#if os(iOS)
private let authRedirectURL = URL(string: "com.tarsy.ios://login-callback")
#elseif os(macOS)
private let authRedirectURL = URL(string: "com.tarsy.macos://login-callback")
#endif

public let supabase = SupabaseClient(
    supabaseURL: TarsyConfig.supabaseURL,
    supabaseKey: TarsyConfig.supabaseAnonKey,
    options: .init(
        auth: .init(
            redirectToURL: authRedirectURL,
            emitLocalSessionAsInitialSession: true
        )
    )
)
