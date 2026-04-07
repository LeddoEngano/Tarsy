using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TarsyWindows.Networking;

// Stub — full implementation in W2 task
public static class WSAction
{
    // System
    public const string Auth = "auth";
    public const string AuthSuccess = "auth:success";
    public const string AuthFail = "auth:fail";
    public const string Ping = "ping";
    public const string Pong = "pong";
    public const string Error = "error";

    // Placeholder — all 143 actions will be added in W2
}

public record WSPacket
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = Guid.NewGuid().ToString();

    [JsonPropertyName("action")]
    public string Action { get; init; } = "";

    [JsonPropertyName("payload")]
    public Dictionary<string, string>? Payload { get; init; }

    [JsonPropertyName("timestamp")]
    public DateTime Timestamp { get; init; } = DateTime.UtcNow;

    public static WSPacket Create(string action, Dictionary<string, string>? payload = null)
    {
        return new WSPacket
        {
            Id = Guid.NewGuid().ToString(),
            Action = action,
            Payload = payload,
            Timestamp = DateTime.UtcNow,
        };
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public string Encode()
    {
        var json = JsonSerializer.Serialize(this, JsonOptions);
        if (json.Length > MaxPacketSize)
            throw new InvalidOperationException($"WSPacket too large: {json.Length} bytes (max {MaxPacketSize})");
        return json;
    }

    public static WSPacket Decode(string json)
    {
        if (json.Length > MaxPacketSize)
            throw new InvalidOperationException($"WSPacket too large: {json.Length} bytes (max {MaxPacketSize})");
        return JsonSerializer.Deserialize<WSPacket>(json, JsonOptions)
            ?? throw new InvalidOperationException("Failed to decode WSPacket");
    }

    private const int MaxPacketSize = 1_048_576; // 1 MB
}
