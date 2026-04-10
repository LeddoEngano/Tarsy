using System;
using System.Management;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using TarsyWindows.Models;
using TarsyWindows.Security;

namespace TarsyWindows.Networking;

/// <summary>
/// Machine registration and heartbeat — mirrors MachineService.swift.
/// </summary>
public class MachineService
{
    public string? MachineId { get; private set; }

    /// <summary>
    /// P-256 keypair identity used for relay auth (Phase 3). The private key
    /// lives in the Windows TPM (Microsoft Platform Crypto Provider) when
    /// available, otherwise in the software key storage provider. Either
    /// way, it's non-exportable from the process.
    /// </summary>
    public MachineKeyStore? KeyStore { get; private set; }

    private static readonly HttpClient Http = new();

    /// <summary>
    /// Register this machine in Supabase.
    /// Detects hardware UUID, hostname, local IP, model.
    /// </summary>
    public async Task Register(SupabaseAuth auth)
    {
        if (string.IsNullOrEmpty(auth.AccessToken) || string.IsNullOrEmpty(auth.UserId))
            return;

        var hwUuid = GetHardwareUuid();
        var hostname = Environment.MachineName;
        var localIp = GetLocalIp();
        var model = GetModelIdentifier();

        // Check if machine already exists
        var existingId = await FindExistingMachine(auth, hwUuid);

        if (existingId != null)
        {
            MachineId = existingId;
            await UpdateMachine(auth, hostname, localIp, model);
        }
        else
        {
            MachineId = await CreateMachine(auth, hwUuid, hostname, localIp, model);
        }

        await EnsureMachineKey(auth);

        Console.WriteLine($"[Machine] Registered: {MachineId} ({hostname})");
    }

    /// <summary>
    /// Send heartbeat — update status to "online".
    /// </summary>
    public async Task Heartbeat(SupabaseAuth auth)
    {
        if (string.IsNullOrEmpty(MachineId) || string.IsNullOrEmpty(auth.AccessToken))
            return;

        await PatchMachine(auth, new
        {
            status = "online",
            last_seen_at = DateTime.UtcNow.ToString("o"),
        });
    }

    /// <summary>
    /// Set machine status to "offline".
    /// </summary>
    public async Task SetOffline(SupabaseAuth auth)
    {
        if (string.IsNullOrEmpty(MachineId)) return;

        await PatchMachine(auth, new
        {
            status = "offline",
            last_seen_at = DateTime.UtcNow.ToString("o"),
        });
    }

    // ── Helpers ──

    private static string GetHardwareUuid()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT UUID FROM Win32_ComputerSystemProduct");
            foreach (var obj in searcher.Get())
            {
                return obj["UUID"]?.ToString() ?? Guid.NewGuid().ToString();
            }
        }
        catch { /* WMI not available */ }

        return Guid.NewGuid().ToString();
    }

    private static string? GetLocalIp()
    {
        try
        {
            foreach (var iface in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (iface.OperationalStatus != OperationalStatus.Up) continue;
                if (iface.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;

                foreach (var addr in iface.GetIPProperties().UnicastAddresses)
                {
                    if (addr.Address.AddressFamily == AddressFamily.InterNetwork)
                    {
                        var ip = addr.Address.ToString();
                        if (ip.StartsWith("192.168.") || ip.StartsWith("10."))
                            return ip;
                        // RFC 1918: 172.16.0.0 – 172.31.255.255
                        if (ip.StartsWith("172."))
                        {
                            var parts = ip.Split('.');
                            if (parts.Length >= 2 && int.TryParse(parts[1], out var second) && second >= 16 && second <= 31)
                                return ip;
                        }
                    }
                }
            }
        }
        catch { /* network detection failed */ }

        return null;
    }

    private static string GetModelIdentifier()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher("SELECT Model FROM Win32_ComputerSystem");
            foreach (var obj in searcher.Get())
            {
                return obj["Model"]?.ToString() ?? "Windows PC";
            }
        }
        catch { /* WMI not available */ }

        return "Windows PC";
    }

    private async Task<string?> FindExistingMachine(SupabaseAuth auth, string hwUuid)
    {
        var url = $"{TarsyConfig.SupabaseUrl}/rest/v1/machines?hardware_uuid=eq.{hwUuid}&user_id=eq.{auth.UserId}&select=id";
        var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Add("apikey", TarsyConfig.SupabaseAnonKey);
        request.Headers.Add("Authorization", $"Bearer {auth.AccessToken}");

        var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return null;

        var json = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(json);
        var arr = doc.RootElement;
        if (arr.GetArrayLength() > 0)
        {
            return arr[0].GetProperty("id").GetString();
        }
        return null;
    }

    private async Task<string?> CreateMachine(SupabaseAuth auth, string hwUuid, string hostname, string? localIp, string model)
    {
        var url = $"{TarsyConfig.SupabaseUrl}/rest/v1/machines";
        var body = JsonSerializer.Serialize(new
        {
            user_id = auth.UserId,
            hardware_uuid = hwUuid,
            hostname,
            local_ip = localIp,
            model_identifier = model,
            status = "online",
            last_seen_at = DateTime.UtcNow.ToString("o"),
        });

        var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        request.Headers.Add("apikey", TarsyConfig.SupabaseAnonKey);
        request.Headers.Add("Authorization", $"Bearer {auth.AccessToken}");
        request.Headers.Add("Prefer", "return=representation");

        var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return null;

        var json = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(json);
        var arr = doc.RootElement;
        if (arr.GetArrayLength() > 0)
        {
            return arr[0].GetProperty("id").GetString();
        }
        return null;
    }

    private async Task UpdateMachine(SupabaseAuth auth, string hostname, string? localIp, string model)
    {
        await PatchMachine(auth, new
        {
            hostname,
            local_ip = localIp,
            model_identifier = model,
            status = "online",
            last_seen_at = DateTime.UtcNow.ToString("o"),
        });
    }

    private async Task PatchMachine(SupabaseAuth auth, object fields)
    {
        var url = $"{TarsyConfig.SupabaseUrl}/rest/v1/machines?id=eq.{MachineId}";
        var body = JsonSerializer.Serialize(fields);

        var request = new HttpRequestMessage(HttpMethod.Patch, url);
        request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        request.Headers.Add("apikey", TarsyConfig.SupabaseAnonKey);
        request.Headers.Add("Authorization", $"Bearer {auth.AccessToken}");

        await Http.SendAsync(request);
    }

    /// <summary>
    /// Loads (or creates) the machine's P-256 identity keypair and uploads
    /// the public key to machine_tokens via the register_machine_public_key
    /// RPC. Idempotent — if the DB already has the matching public key, this
    /// is a no-op. Called once during Register().
    /// </summary>
    private async Task EnsureMachineKey(SupabaseAuth auth)
    {
        if (string.IsNullOrEmpty(MachineId) || string.IsNullOrEmpty(auth.AccessToken))
            return;

        try
        {
            KeyStore = MachineKeyStore.LoadOrCreate();
            var localHex = @"\x" + Convert.ToHexString(KeyStore.PublicKeyDer).ToLowerInvariant();

            // Fetch current DB value (avoid bumping rotated_at on every boot)
            var getUrl = $"{TarsyConfig.SupabaseUrl}/rest/v1/machine_tokens?machine_id=eq.{MachineId}&select=public_key";
            using var getReq = new HttpRequestMessage(HttpMethod.Get, getUrl);
            getReq.Headers.Add("apikey", TarsyConfig.SupabaseAnonKey);
            getReq.Headers.Add("Authorization", $"Bearer {auth.AccessToken}");
            var getResp = await Http.SendAsync(getReq);

            bool needsUpload = true;
            if (getResp.IsSuccessStatusCode)
            {
                var getJson = await getResp.Content.ReadAsStringAsync();
                using var getDoc = JsonDocument.Parse(getJson);
                if (getDoc.RootElement.ValueKind == JsonValueKind.Array && getDoc.RootElement.GetArrayLength() > 0)
                {
                    var row = getDoc.RootElement[0];
                    if (row.TryGetProperty("public_key", out var pk) && pk.ValueKind == JsonValueKind.String)
                    {
                        var dbHex = pk.GetString();
                        if (string.Equals(dbHex, localHex, StringComparison.OrdinalIgnoreCase))
                        {
                            needsUpload = false;
                            Console.WriteLine($"[Machine] EnsureMachineKey: already up-to-date (backend={KeyStore.Backend})");
                        }
                    }
                }
            }

            if (needsUpload)
            {
                var rpcUrl = $"{TarsyConfig.SupabaseUrl}/rest/v1/rpc/register_machine_public_key";
                var body = JsonSerializer.Serialize(new
                {
                    p_machine_id = MachineId,
                    p_public_key = localHex,
                });
                using var rpcReq = new HttpRequestMessage(HttpMethod.Post, rpcUrl);
                rpcReq.Content = new StringContent(body, Encoding.UTF8, "application/json");
                rpcReq.Headers.Add("apikey", TarsyConfig.SupabaseAnonKey);
                rpcReq.Headers.Add("Authorization", $"Bearer {auth.AccessToken}");
                var rpcResp = await Http.SendAsync(rpcReq);
                if (rpcResp.IsSuccessStatusCode)
                {
                    Console.WriteLine($"[Machine] EnsureMachineKey: uploaded public key ({KeyStore.PublicKeyDer.Length} bytes, backend={KeyStore.Backend})");
                }
                else
                {
                    var err = await rpcResp.Content.ReadAsStringAsync();
                    Console.WriteLine($"[Machine] EnsureMachineKey: upload failed {rpcResp.StatusCode}: {err}");
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Machine] EnsureMachineKey error: {ex.Message}");
            // Don't crash — legacy machineSecret path still works if the relay hasn't
            // been updated yet, and the relay supports both flows during transition.
        }
    }
}
