using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace TarsyWindows.Services;

/// <summary>
/// MCP (Model Context Protocol) server discovery and health checking.
/// Mirrors macOS MCP health check functionality.
/// </summary>
public static class McpHealthService
{
    private static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    }) { Timeout = TimeSpan.FromSeconds(5) };

    /// <summary>
    /// Scan for MCP server configs across all known agent directories.
    /// </summary>
    public static async Task<List<Dictionary<string, string>>> ScanAndCheck()
    {
        var results = new List<Dictionary<string, string>>();
        var configs = DiscoverMcpConfigs();

        foreach (var config in configs)
        {
            var health = await CheckHealth(config);
            results.Add(health);
        }

        return results;
    }

    /// <summary>
    /// Discover MCP server configurations from agent config directories.
    /// </summary>
    public static List<McpServerConfig> DiscoverMcpConfigs()
    {
        var configs = new List<McpServerConfig>();
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

        // Known MCP config locations
        string[] configPaths =
        {
            // Claude Code
            Path.Combine(home, ".claude", "mcp_servers.json"),
            Path.Combine(home, ".claude.json"),
            // VS Code
            Path.Combine(appData, "Code", "User", "globalStorage", "saoudrizwan.claude-dev", "settings", "cline_mcp_settings.json"),
            // Cursor
            Path.Combine(home, ".cursor", "mcp.json"),
            // Generic
            Path.Combine(home, ".config", "mcp", "servers.json"),
        };

        foreach (var configPath in configPaths)
        {
            if (!File.Exists(configPath)) continue;

            try
            {
                var json = File.ReadAllText(configPath);
                using var doc = JsonDocument.Parse(json);
                var root = doc.RootElement;

                // Handle different config formats
                if (root.TryGetProperty("mcpServers", out var servers) ||
                    root.TryGetProperty("mcp_servers", out servers) ||
                    root.TryGetProperty("servers", out servers))
                {
                    foreach (var server in servers.EnumerateObject())
                    {
                        var config = ParseServerConfig(server.Name, server.Value, configPath);
                        if (config != null)
                            configs.Add(config);
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[MCP] Error reading {configPath}: {ex.Message}");
            }
        }

        return configs;
    }

    private static McpServerConfig? ParseServerConfig(string name, JsonElement element, string source)
    {
        var config = new McpServerConfig { Name = name, Source = source };

        if (element.TryGetProperty("command", out var cmd))
            config.Command = cmd.GetString();

        if (element.TryGetProperty("url", out var url))
            config.Url = url.GetString();

        if (element.TryGetProperty("args", out var args) && args.ValueKind == JsonValueKind.Array)
            config.Args = args.EnumerateArray().Select(a => a.GetString() ?? "").ToArray();

        if (element.TryGetProperty("env", out var env) && env.ValueKind == JsonValueKind.Object)
        {
            config.Env = new Dictionary<string, string>();
            foreach (var prop in env.EnumerateObject())
                config.Env[prop.Name] = prop.Value.GetString() ?? "";
        }

        return config;
    }

    /// <summary>
    /// Check health of a specific MCP server.
    /// </summary>
    public static async Task<Dictionary<string, string>> CheckHealth(McpServerConfig config)
    {
        var result = new Dictionary<string, string>
        {
            ["name"] = config.Name,
            ["source"] = Path.GetFileName(config.Source),
            ["type"] = config.Url != null ? "http" : "stdio",
        };

        if (config.Url != null)
        {
            // HTTP-based MCP server — check health endpoint
            try
            {
                var response = await Http.GetAsync(config.Url);
                result["status"] = response.IsSuccessStatusCode ? "healthy" : "unhealthy";
                result["statusCode"] = ((int)response.StatusCode).ToString();
            }
            catch (Exception ex)
            {
                result["status"] = "unreachable";
                result["error"] = ex.Message;
            }
        }
        else if (config.Command != null)
        {
            // stdio-based MCP server — check if binary exists
            var binaryExists = File.Exists(config.Command);
            if (!binaryExists)
            {
                // Try resolving via PATH
                try
                {
                    using var process = new System.Diagnostics.Process();
                    process.StartInfo = new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = "where.exe",
                        RedirectStandardOutput = true,
                        UseShellExecute = false,
                        CreateNoWindow = true,
                    };
                    process.StartInfo.ArgumentList.Add(config.Command);
                    process.Start();
                    var output = await process.StandardOutput.ReadToEndAsync();
                    process.WaitForExit(3000);
                    binaryExists = process.ExitCode == 0 && !string.IsNullOrWhiteSpace(output);
                }
                catch
                {
                    binaryExists = false;
                }
            }

            result["status"] = binaryExists ? "available" : "not_found";
            result["command"] = config.Command;
            if (config.Args != null)
                result["args"] = string.Join(" ", config.Args);
        }
        else
        {
            result["status"] = "unknown";
        }

        return result;
    }

    public record McpServerConfig
    {
        public string Name { get; set; } = "";
        public string Source { get; set; } = "";
        public string? Command { get; set; }
        public string? Url { get; set; }
        public string[]? Args { get; set; }
        public Dictionary<string, string>? Env { get; set; }
    }
}
