import Foundation
import Supabase

public let supabase = SupabaseClient(
    supabaseURL: TarsyConfig.supabaseURL,
    supabaseKey: TarsyConfig.supabaseAnonKey,
    options: .init(
        auth: .init(
            redirectToURL: URL(string: "com.tarsy.ios://login-callback"),
            emitLocalSessionAsInitialSession: true
        )
    )
)
