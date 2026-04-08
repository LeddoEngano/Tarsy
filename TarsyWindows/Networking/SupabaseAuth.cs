using System;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using TarsyWindows.Models;

namespace TarsyWindows.Networking;

/// <summary>
/// Supabase auth client with Windows Credential Manager persistence.
/// </summary>
public class SupabaseAuth
{
    private static readonly HttpClient Http = new();
    private string? _accessToken;
    private string? _refreshTokenValue;

    private const string CredentialTarget = "Tarsy/SupabaseSession";

    public string? AccessToken => _accessToken;
    public string? UserId { get; private set; }

    /// <summary>
    /// Load existing session from Windows Credential Manager.
    /// Falls back to TARSY_TOKEN env var.
    /// </summary>
    public async Task<string?> LoadSession()
    {
        // Try Credential Manager first
        var stored = CredentialStore.Read(CredentialTarget);
        if (stored != null)
        {
            try
            {
                using var doc = JsonDocument.Parse(stored);
                _accessToken = doc.RootElement.GetProperty("access_token").GetString();
                _refreshTokenValue = doc.RootElement.GetProperty("refresh_token").GetString();
                UserId = doc.RootElement.GetProperty("user_id").GetString();

                // Try refreshing the token to ensure it's still valid
                if (!string.IsNullOrEmpty(_refreshTokenValue))
                {
                    var refreshed = await RefreshToken();
                    if (refreshed != null) return refreshed;
                }

                if (!string.IsNullOrEmpty(_accessToken)) return _accessToken;
            }
            catch
            {
                // Corrupted credential — ignore and fall through
            }
        }

        // Fallback: env var
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

        // Persist to Credential Manager
        SaveSession();

        return _accessToken;
    }

    /// <summary>
    /// Sign in with GitHub OAuth via browser redirect.
    /// </summary>
    public async Task<string?> SignInWithGitHub()
    {
        using var oauth = new OAuthServer();
        var result = await oauth.StartGitHubOAuth();

        if (string.IsNullOrEmpty(result.AccessToken)) return null;

        _accessToken = result.AccessToken;
        _refreshTokenValue = result.RefreshToken;

        // Fetch user ID from the token
        await FetchUserId();

        SaveSession();
        return _accessToken;
    }

    private async Task FetchUserId()
    {
        if (string.IsNullOrEmpty(_accessToken)) return;
        try
        {
            var request = new HttpRequestMessage(HttpMethod.Get, $"{TarsyConfig.SupabaseUrl}/auth/v1/user");
            request.Headers.Add("apikey", TarsyConfig.SupabaseAnonKey);
            request.Headers.Add("Authorization", $"Bearer {_accessToken}");

            var response = await Http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return;

            var json = await response.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(json);
            UserId = doc.RootElement.GetProperty("id").GetString();
        }
        catch { }
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

        // Update stored credentials
        SaveSession();

        return _accessToken;
    }

    /// <summary>
    /// Clear stored session (sign out).
    /// </summary>
    public void SignOut()
    {
        _accessToken = null;
        _refreshTokenValue = null;
        UserId = null;
        CredentialStore.Delete(CredentialTarget);
    }

    private void SaveSession()
    {
        if (_accessToken == null) return;
        var data = JsonSerializer.Serialize(new
        {
            access_token = _accessToken,
            refresh_token = _refreshTokenValue ?? "",
            user_id = UserId ?? "",
        });
        CredentialStore.Write(CredentialTarget, data);
    }
}

/// <summary>
/// Thin wrapper around Windows Credential Manager (DPAPI-protected).
/// </summary>
internal static class CredentialStore
{
    public static string? Read(string target)
    {
        bool ok = CredRead(target, 1 /* CRED_TYPE_GENERIC */, 0, out IntPtr credPtr);
        if (!ok) return null;
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(credPtr);
            if (cred.CredentialBlobSize == 0 || cred.CredentialBlob == IntPtr.Zero) return null;
            return Marshal.PtrToStringUni(cred.CredentialBlob, (int)cred.CredentialBlobSize / 2);
        }
        finally
        {
            CredFree(credPtr);
        }
    }

    public static void Write(string target, string data)
    {
        var bytes = Encoding.Unicode.GetBytes(data);
        var cred = new CREDENTIAL
        {
            Type = 1, // CRED_TYPE_GENERIC
            TargetName = target,
            CredentialBlobSize = (uint)bytes.Length,
            CredentialBlob = Marshal.AllocHGlobal(bytes.Length),
            Persist = 2, // CRED_PERSIST_LOCAL_MACHINE
            UserName = "TarsyWindows",
        };
        try
        {
            Marshal.Copy(bytes, 0, cred.CredentialBlob, bytes.Length);
            CredWrite(ref cred, 0);
        }
        finally
        {
            Marshal.FreeHGlobal(cred.CredentialBlob);
        }
    }

    public static void Delete(string target)
    {
        CredDelete(target, 1, 0);
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredRead(string target, int type, int reserved, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern void CredFree(IntPtr credential);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
}
