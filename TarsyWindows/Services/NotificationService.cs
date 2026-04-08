using System;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace TarsyWindows.Services;

/// <summary>
/// Push notification dispatch — local Toast + remote via Supabase.
/// Mirrors macOS PushNotificationService.
/// </summary>
public class NotificationService : IDisposable
{
    private readonly HttpClient _http = new();
    private string? _supabaseUrl;
    private string? _authToken;
    private string? _userId;

    // ── Win32 for balloon notifications (works on all Windows 10/11) ──

    /// <summary>
    /// Initialize with auth credentials for remote notifications.
    /// </summary>
    public void Initialize(string supabaseUrl, string authToken, string userId)
    {
        _supabaseUrl = supabaseUrl;
        _authToken = authToken;
        _userId = userId;

        _http.DefaultRequestHeaders.Authorization =
            new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", authToken);
    }

    /// <summary>
    /// Show a local Windows toast notification.
    /// Uses PowerShell to invoke Windows.UI.Notifications API.
    /// </summary>
    public static void ShowLocal(string title, string body, string? tag = null)
    {
        try
        {
            // Use PowerShell to show toast — works without WinRT reference
            var xml = $@"
<toast>
  <visual>
    <binding template='ToastGeneric'>
      <text>{EscapeXml(title)}</text>
      <text>{EscapeXml(body)}</text>
    </binding>
  </visual>
</toast>".Trim();

            var script = $@"
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml('{xml.Replace("'", "''")}')

$toast = New-Object Windows.UI.Notifications.ToastNotification($xml)
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Tarsy')
$notifier.Show($toast)
";

            using var process = new System.Diagnostics.Process();
            process.StartInfo = new System.Diagnostics.ProcessStartInfo
            {
                FileName = "powershell.exe",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            process.StartInfo.ArgumentList.Add("-NoProfile");
            process.StartInfo.ArgumentList.Add("-ExecutionPolicy");
            process.StartInfo.ArgumentList.Add("Bypass");
            process.StartInfo.ArgumentList.Add("-Command");
            process.StartInfo.ArgumentList.Add(script);

            process.Start();
            process.WaitForExit(5000);

            Console.WriteLine($"[Notification] Local toast: {title}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Notification] Toast error: {ex.Message}");
        }
    }

    /// <summary>
    /// Send a remote push notification via Supabase push_notifications table.
    /// This triggers the send-push edge function to deliver via APNs.
    /// </summary>
    public async Task SendRemote(string title, string body, string? targetUserId = null)
    {
        if (_supabaseUrl == null || _authToken == null) return;

        try
        {
            var payload = JsonSerializer.Serialize(new
            {
                user_id = targetUserId ?? _userId,
                title,
                body,
                created_at = DateTime.UtcNow.ToString("o"),
            });

            var response = await _http.PostAsync(
                $"{_supabaseUrl}/rest/v1/push_notifications",
                new StringContent(payload, Encoding.UTF8, "application/json")
            );

            if (response.IsSuccessStatusCode)
            {
                Console.WriteLine($"[Notification] Remote push sent: {title}");
            }
            else
            {
                Console.WriteLine($"[Notification] Remote push failed: {response.StatusCode}");
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[Notification] Remote push error: {ex.Message}");
        }
    }

    /// <summary>
    /// Notify about agent activity (both local and remote).
    /// </summary>
    public async Task NotifyAgentEvent(string eventType, string details)
    {
        var title = eventType switch
        {
            "completed" => "Agent Completed",
            "error" => "Agent Error",
            "waiting" => "Agent Waiting for Input",
            "permission" => "Permission Required",
            _ => "Tarsy Agent",
        };

        // Local toast
        ShowLocal(title, details);

        // Remote push
        await SendRemote(title, details);
    }

    private static string EscapeXml(string text)
    {
        return text
            .Replace("&", "&amp;")
            .Replace("<", "&lt;")
            .Replace(">", "&gt;")
            .Replace("\"", "&quot;")
            .Replace("'", "&apos;")
            .Replace("`", "``")  // Escape backticks first
            .Replace("$", "`$"); // Then escape dollar signs (prevents PowerShell injection)
    }

    public void Dispose()
    {
        _http.Dispose();
    }
}
