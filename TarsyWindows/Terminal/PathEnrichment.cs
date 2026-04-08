using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace TarsyWindows.Terminal;

/// <summary>
/// PATH enrichment for terminal sessions — adds common dev tool paths.
/// Mirrors macOS TerminalSessionManager.enrichPath().
/// </summary>
public static class PathEnrichment
{
    public static string GetEnrichedPath()
    {
        var currentPath = Environment.GetEnvironmentVariable("PATH") ?? "";
        var extraPaths = new List<string>();

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

        // User local bin
        AddIfExists(extraPaths, Path.Combine(home, ".local", "bin"));

        // Bun
        AddIfExists(extraPaths, Path.Combine(home, ".bun", "bin"));

        // Cargo / Rust
        AddIfExists(extraPaths, Path.Combine(home, ".cargo", "bin"));

        // nvm for Windows — scan for installed versions
        var nvmDir = Path.Combine(appData, "nvm");
        if (Directory.Exists(nvmDir))
        {
            try
            {
                foreach (var versionDir in Directory.EnumerateDirectories(nvmDir, "v*"))
                {
                    AddIfExists(extraPaths, versionDir);
                }
            }
            catch { }
        }

        // fnm
        var fnmDir = Path.Combine(localAppData, "fnm", "node-versions");
        if (Directory.Exists(fnmDir))
        {
            try
            {
                foreach (var versionDir in Directory.EnumerateDirectories(fnmDir))
                {
                    var installDir = Path.Combine(versionDir, "installation");
                    AddIfExists(extraPaths, installDir);
                }
            }
            catch { }
        }

        // Volta
        AddIfExists(extraPaths, Path.Combine(home, ".volta", "bin"));

        // Go
        AddIfExists(extraPaths, Path.Combine(home, "go", "bin"));
        AddIfExists(extraPaths, Path.Combine(home, ".go", "bin"));

        // pnpm
        AddIfExists(extraPaths, Path.Combine(appData, "pnpm"));

        // Python — scan for installed versions
        var pythonBase = Path.Combine(localAppData, "Programs", "Python");
        if (Directory.Exists(pythonBase))
        {
            try
            {
                foreach (var pyDir in Directory.EnumerateDirectories(pythonBase, "Python*"))
                {
                    AddIfExists(extraPaths, pyDir);
                    AddIfExists(extraPaths, Path.Combine(pyDir, "Scripts"));
                }
            }
            catch { }
        }

        // pyenv for Windows
        AddIfExists(extraPaths, Path.Combine(home, ".pyenv", "pyenv-win", "shims"));
        AddIfExists(extraPaths, Path.Combine(home, ".pyenv", "pyenv-win", "bin"));

        // npm global
        AddIfExists(extraPaths, Path.Combine(appData, "npm"));

        // Deno
        AddIfExists(extraPaths, Path.Combine(home, ".deno", "bin"));

        if (extraPaths.Count == 0)
            return currentPath;

        return string.Join(';', extraPaths) + ";" + currentPath;
    }

    private static void AddIfExists(List<string> paths, string path)
    {
        if (Directory.Exists(path) && !paths.Contains(path))
        {
            paths.Add(path);
        }
    }
}
