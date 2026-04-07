using System;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using TarsyWindows.Models;

namespace TarsyWindows.Networking;

/// <summary>
/// Supabase auth client — email/password sign-in with DPAPI token storage.
/// Stub — full implementation in W3 task.
/// </summary>
public class SupabaseAuth
{
    private static readonly HttpClient Http = new();
    private string? _accessToken;
    private string? _refreshTokenValue;

    public string? AccessToken => _accessToken;
    public string? UserId { get; private set; }

    /// <summary>
    /// Load existing session from DPAPI-protected storage.
    /// Returns access token or null if not signed in.
    /// </summary>
    public async Task<string?> LoadSession()
    {
        // TODO: Load from Windows Credential Manager (DPAPI)
        // For now, check environment variable as fallback
        _accessToken = Environment.GetEnvironmentVariable("TARSY_TOKEN");
        return _accessToken;
    }

    /// <summary>
    /// Sign in with email and password.
    /// </summary>
    public async Task<string?> SignIn(string email, string password)
    {
        var url = $"{TarsyConfig.SupabaseUrl}/auth/v1/token?grant_type=password";
        var body = JsonSerializer.Serialize(new { email, password });

        var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        request.Headers.Add("apikey", TarsyConfig.SupabaseAnonKey);

        var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return null;

        var json = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(json);
        _accessToken = doc.RootElement.GetProperty("access_token").GetString();
        _refreshTokenValue = doc.RootElement.GetProperty("refresh_token").GetString();
        UserId = doc.RootElement.GetProperty("user").GetProperty("id").GetString();

        // TODO: Store in Windows Credential Manager
        return _accessToken;
    }

    /// <summary>
    /// Refresh the access token using the refresh token.
    /// </summary>
    public async Task<string?> RefreshToken()
    {
        if (string.IsNullOrEmpty(_refreshTokenValue)) return _accessToken;

        var url = $"{TarsyConfig.SupabaseUrl}/auth/v1/token?grant_type=refresh_token";
        var body = JsonSerializer.Serialize(new { refresh_token = _refreshTokenValue });

        var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        request.Headers.Add("apikey", TarsyConfig.SupabaseAnonKey);

        var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return _accessToken;

        var json = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(json);
        _accessToken = doc.RootElement.GetProperty("access_token").GetString();
        _refreshTokenValue = doc.RootElement.GetProperty("refresh_token").GetString();

        return _accessToken;
    }
}
