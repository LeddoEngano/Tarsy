using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace TarsyWindows.Terminal;

/// <summary>
/// Detects installed AI coding agents — mirrors macOS AgentDetector.
/// </summary>
public static class AgentDetector
{
    public record AgentInfo(string Name, string Path, string? Version);

    private static List<AgentInfo>? _cachedAgents;
    private static DateTime _cacheTime = DateTime.MinValue;
    private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(10);
    private static readonly SemaphoreSlim _scanLock = new(1, 1);

    /// <summary>
    /// Return cached agents, or scan if cache is stale/empty.
    /// </summary>
    public static async Task<List<AgentInfo>> DetectAll(bool forceRefresh = false)
    {
        if (!forceRefresh && _cachedAgents != null && DateTime.UtcNow - _cacheTime < CacheTtl)
            return _cachedAgents;

        await _scanLock.WaitAsync();
        try
        {
            // Double-check after acquiring lock
            if (!forceRefresh && _cachedAgents != null && DateTime.UtcNow - _cacheTime < CacheTtl)
                return _cachedAgents;

            _cachedAgents = await ScanAll();
            _cacheTime = DateTime.UtcNow;
            return _cachedAgents;
        }
        finally
        {
            _scanLock.Release();
        }
    }

    /// <summary>
    /// Scan for all installed AI agents on this Windows machine.
    /// </summary>
    private static async Task<List<AgentInfo>> ScanAll()
    {
        var agents = new List<AgentInfo>();

        var detectors = new (string name, string[] binNames, string[][] searchPaths)[]
        {
            ("claude_code", new[] { "claude.exe", "claude.cmd" }, new[]
            {
                new[] { Home, ".claude", "bin" },
                new[] { AppData, "npm" },
                new[] { LocalAppData, "pnpm" },
                new[] { Home, ".bun", "bin" },
                new[] { Home, ".volta", "bin" },
            }),
            ("gemini", new[] { "gemini.exe", "gemini.cmd" }, new[]
            {
                new[] { AppData, "npm" },
                new[] { LocalAppData, "pnpm" },
                new[] { Home, ".bun", "bin" },
            }),
            ("codex", new[] { "codex.exe", "codex.cmd" }, new[]
            {
                new[] { AppData, "npm" },
                new[] { LocalAppData, "pnpm" },
                new[] { Home, ".bun", "bin" },
            }),
            ("aider", new[] { "aider.exe" }, new[]
            {
                new[] { Home, ".local", "bin" },
                new[] { LocalAppData, "Programs", "Python", "*", "Scripts" },
                new[] { Home, ".pyenv", "pyenv-win", "shims" },
            }),
        };

        foreach (var (name, binNames, searchPaths) in detectors)
        {
            var found = FindAgent(binNames, searchPaths);
            if (found == null)
            {
                // Fallback: where.exe
                found = await FindViaWhere(binNames.First());
            }

            if (found != null)
            {
                var version = await GetVersion(found, name);
                agents.Add(new AgentInfo(name, found, version));
            }
        }

        return agents;
    }

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    private static string AppData => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    private static string LocalAppData => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    private static string? FindAgent(string[] binNames, string[][] searchPaths)
    {
        foreach (var pathParts in searchPaths)
        {
            // Handle wildcard paths
            if (pathParts.Any(p => p == "*"))
            {
                var wildcardIdx = Array.IndexOf(pathParts, "*");
                var basePath = Path.Combine(pathParts.Take(wildcardIdx).ToArray());

                if (!Directory.Exists(basePath)) continue;

                try
                {
                    foreach (var dir in Directory.EnumerateDirectories(basePath))
                    {
                        var remaining = pathParts.Skip(wildcardIdx + 1).ToArray();
                        var candidateDir = remaining.Length > 0
                            ? Path.Combine(new[] { dir }.Concat(remaining).ToArray())
                            : dir;

                        foreach (var bin in binNames)
                        {
                            var fullPath = Path.Combine(candidateDir, bin);
                            if (File.Exists(fullPath)) return fullPath;
                        }
                    }
                }
                catch { }
            }
            else
            {
                var dir = Path.Combine(pathParts);
                foreach (var bin in binNames)
                {
                    var fullPath = Path.Combine(dir, bin);
                    if (File.Exists(fullPath)) return fullPath;
                }
            }
        }

        return null;
    }

    private static async Task<string?> FindViaWhere(string binary)
    {
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "where.exe",
                    Arguments = binary,
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }
            };
            process.Start();
            var output = await process.StandardOutput.ReadToEndAsync();

            using var cts = new CancellationTokenSource(5000);
            await process.WaitForExitAsync(cts.Token);

            var firstLine = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();
            if (firstLine != null && File.Exists(firstLine))
                return firstLine;
        }
        catch { }

        return null;
    }

    private static async Task<string?> GetVersion(string agentPath, string name)
    {
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = agentPath,
                    Arguments = "--version",
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }
            };
            process.Start();
            var output = await process.StandardOutput.ReadToEndAsync();

            using var cts = new CancellationTokenSource(5000);
            await process.WaitForExitAsync(cts.Token);

            return output.Trim().Split('\n').FirstOrDefault()?.Trim();
        }
        catch
        {
            return null;
        }
    }
}
