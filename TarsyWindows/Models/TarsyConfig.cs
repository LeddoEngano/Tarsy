namespace TarsyWindows.Models;

/// <summary>
/// Configuration constants — mirrors TarsyShared/Config.swift.
/// </summary>
public static class TarsyConfig
{
    public const string SupabaseUrl = "https://xtblbghhlkroskzljqcl.supabase.co";
    public const string SupabaseAnonKey = "sb_publishable_J_nOhA2NRFGtz7W1vd_ZaA_2St0Emzs";
    public const string RelayUrl = "wss://tarsy-relay.fly.dev/ws";
    public const string RelayDevUrl = "ws://localhost:8080/ws";
    public const int WebSocketPort = 8642;
}
