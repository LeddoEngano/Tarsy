using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace TarsyWindows.Services;

/// <summary>
/// Workspace orchestration — git clone, stack detection, repo scanning.
/// Mirrors macOS WorkspaceOrchestrator + RepoScanner.
/// </summary>
public static class WorkspaceOrchestrator
{
    // ── Repo Scanning ──

    private static readonly string[] ScanDirectories =
    {
        "Desktop", "Documents", "Projects", "Developer", "Code",
        "repos", "dev", "work", "src", "GitHub",
    };

    /// <summary>
    /// Scan standard directories for git repos.
    /// Returns list of { name, path, stack, lastModified }.
    /// </summary>
    public static async Task<List<Dictionary<string, string>>> ScanRepos()
    {
        var repos = new List<Dictionary<string, string>>();
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        var tasks = ScanDirectories
            .Select(dir => Path.Combine(home, dir))
            .Where(Directory.Exists)
            .Select(dir => Task.Run(() => ScanDirectory(dir, repos, maxDepth: 2)));

        await Task.WhenAll(tasks);

        return repos
            .OrderByDescending(r => r.GetValueOrDefault("lastModified", ""))
            .ToList();
    }

    private static void ScanDirectory(string path, List<Dictionary<string, string>> repos, int maxDepth, int depth = 0)
    {
        if (depth > maxDepth) return;

        try
        {
            // Check if this is a git repo
            if (Directory.Exists(Path.Combine(path, ".git")))
            {
                var name = Path.GetFileName(path);
                var stack = DetectStack(path);
                var lastModified = Directory.GetLastWriteTimeUtc(path).ToString("o");

                lock (repos)
                {
                    repos.Add(new Dictionary<string, string>
                    {
                        ["name"] = name,
                        ["path"] = path.Replace('\\', '/'),
                        ["stack"] = stack,
                        ["lastModified"] = lastModified,
                    });
                }
                return; // Don't recurse into git repos
            }

            foreach (var subDir in Directory.EnumerateDirectories(path))
            {
                var dirName = Path.GetFileName(subDir);
                if (dirName.StartsWith('.') || dirName == "node_modules" || dirName == "vendor")
                    continue;

                ScanDirectory(subDir, repos, maxDepth, depth + 1);
            }
        }
        catch (UnauthorizedAccessException) { }
        catch (IOException) { }
    }

    // ── Stack Detection ──

    /// <summary>
    /// Detect the tech stack by looking for marker files.
    /// </summary>
    public static string DetectStack(string repoPath)
    {
        var markers = new List<string>();

        // JavaScript / TypeScript
        if (File.Exists(Path.Combine(repoPath, "package.json")))
        {
            markers.Add("node");

            // Framework detection
            if (File.Exists(Path.Combine(repoPath, "next.config.js")) ||
                File.Exists(Path.Combine(repoPath, "next.config.mjs")) ||
                File.Exists(Path.Combine(repoPath, "next.config.ts")))
                markers.Add("nextjs");
            else if (Directory.Exists(Path.Combine(repoPath, "src", "app")) &&
                     File.Exists(Path.Combine(repoPath, "angular.json")))
                markers.Add("angular");
            else if (File.Exists(Path.Combine(repoPath, "vite.config.ts")) ||
                     File.Exists(Path.Combine(repoPath, "vite.config.js")))
                markers.Add("vite");

            if (File.Exists(Path.Combine(repoPath, "tsconfig.json")))
                markers.Add("typescript");
        }

        // Python
        if (File.Exists(Path.Combine(repoPath, "requirements.txt")) ||
            File.Exists(Path.Combine(repoPath, "pyproject.toml")) ||
            File.Exists(Path.Combine(repoPath, "setup.py")) ||
            File.Exists(Path.Combine(repoPath, "Pipfile")))
        {
            markers.Add("python");
            if (File.Exists(Path.Combine(repoPath, "manage.py")))
                markers.Add("django");
            if (Directory.GetFiles(repoPath, "*.ipynb", SearchOption.TopDirectoryOnly).Length > 0)
                markers.Add("jupyter");
        }

        // Rust
        if (File.Exists(Path.Combine(repoPath, "Cargo.toml")))
            markers.Add("rust");

        // Go
        if (File.Exists(Path.Combine(repoPath, "go.mod")))
            markers.Add("go");

        // .NET / C#
        if (Directory.GetFiles(repoPath, "*.csproj", SearchOption.TopDirectoryOnly).Length > 0 ||
            Directory.GetFiles(repoPath, "*.sln", SearchOption.TopDirectoryOnly).Length > 0)
            markers.Add("dotnet");

        // Java / Kotlin
        if (File.Exists(Path.Combine(repoPath, "pom.xml")))
            markers.Add("java-maven");
        else if (File.Exists(Path.Combine(repoPath, "build.gradle")) ||
                 File.Exists(Path.Combine(repoPath, "build.gradle.kts")))
            markers.Add("java-gradle");

        // Swift
        if (File.Exists(Path.Combine(repoPath, "Package.swift")))
            markers.Add("swift");

        // Docker
        if (File.Exists(Path.Combine(repoPath, "Dockerfile")) ||
            File.Exists(Path.Combine(repoPath, "docker-compose.yml")) ||
            File.Exists(Path.Combine(repoPath, "docker-compose.yaml")))
            markers.Add("docker");

        return markers.Count > 0 ? string.Join(",", markers) : "unknown";
    }

    // ── Package Manager Detection ──

    /// <summary>
    /// Detect which package manager the project uses.
    /// </summary>
    public static string DetectPackageManager(string repoPath)
    {
        if (File.Exists(Path.Combine(repoPath, "bun.lockb")) ||
            File.Exists(Path.Combine(repoPath, "bun.lock")))
            return "bun";
        if (File.Exists(Path.Combine(repoPath, "pnpm-lock.yaml")))
            return "pnpm";
        if (File.Exists(Path.Combine(repoPath, "yarn.lock")))
            return "yarn";
        if (File.Exists(Path.Combine(repoPath, "package-lock.json")))
            return "npm";
        if (File.Exists(Path.Combine(repoPath, "Pipfile.lock")))
            return "pipenv";
        if (File.Exists(Path.Combine(repoPath, "poetry.lock")))
            return "poetry";

        return "unknown";
    }

    /// <summary>
    /// Extract dev server command from package.json scripts.
    /// </summary>
    public static string? GetDevServerCommand(string repoPath)
    {
        var packageJsonPath = Path.Combine(repoPath, "package.json");
        if (!File.Exists(packageJsonPath)) return null;

        try
        {
            var json = File.ReadAllText(packageJsonPath);
            using var doc = JsonDocument.Parse(json);

            if (!doc.RootElement.TryGetProperty("scripts", out var scripts))
                return null;

            // Priority: dev > start > serve
            string[] priorities = { "dev", "start", "serve", "dev:start" };
            foreach (var key in priorities)
            {
                if (scripts.TryGetProperty(key, out var val))
                {
                    var pm = DetectPackageManager(repoPath);
                    var runner = pm switch
                    {
                        "bun" => "bun run",
                        "pnpm" => "pnpm run",
                        "yarn" => "yarn",
                        _ => "npm run",
                    };
                    return $"{runner} {key}";
                }
            }
        }
        catch { }

        return null;
    }
}
