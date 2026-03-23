import Foundation
import Supabase

public let supabase = SupabaseClient(
    supabaseURL: TarsyConfig.supabaseURL,
    supabaseKey: TarsyConfig.supabaseAnonKey,
    options: .init(
        auth: .init(emitLocalSessionAsInitialSession: true)
    )
)
