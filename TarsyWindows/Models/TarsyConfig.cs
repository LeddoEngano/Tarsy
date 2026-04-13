using System;

namespace TarsyWindows.Models;

/// <summary>
/// Configuration — reads from environment variables.
/// Copy .env.template to .env and fill in your values, or set environment variables directly.
/// </summary>
public static class TarsyConfig
{
    public static string SupabaseUrl =>
        Environment.GetEnvironmentVariable("TARSY_SUPABASE_URL")
        ?? throw new InvalidOperationException("TARSY_SUPABASE_URL not set. See .env.template.");

    public static string SupabaseAnonKey =>
        Environment.GetEnvironmentVariable("TARSY_SUPABASE_ANON_KEY")
        ?? throw new InvalidOperationException("TARSY_SUPABASE_ANON_KEY not set. See .env.template.");

    public static string RelayUrl =>
        Environment.GetEnvironmentVariable("TARSY_RELAY_URL")
        ?? "wss://tarsy-relay.fly.dev/ws";

    public const string RelayDevUrl = "ws://localhost:8080/ws";
    public const int WebSocketPort = 8642;
}
