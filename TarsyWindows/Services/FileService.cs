using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace TarsyWindows.Services;

/// <summary>
/// File operations — mirrors macOS file:tree and file:read handlers.
/// </summary>
public static class FileService
{
    private static readonly HashSet<string> SkipDirs = new(StringComparer.OrdinalIgnoreCase)
    {
        ".git", "node_modules", ".next", ".nuxt", "dist", "build", "out",
        "__pycache__", ".pytest_cache", ".mypy_cache", "venv", ".venv", "env",
        ".tox", "target", "bin", "obj", ".vs", ".idea", ".gradle",
        "Pods", ".build", "DerivedData", ".swiftpm", "vendor",
        "coverage", ".nyc_output", ".turbo", ".cache", ".parcel-cache",
    };

    private static readonly HashSet<string> BinaryExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".exe", ".dll", ".so", ".dylib", ".o", ".a", ".lib",
        ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp",
        ".mp3", ".mp4", ".wav", ".avi", ".mov", ".mkv",
        ".zip", ".tar", ".gz", ".rar", ".7z",
        ".pdf", ".doc", ".docx", ".xls", ".xlsx",
        ".woff", ".woff2", ".ttf", ".eot",
        ".pyc", ".class", ".pdb",
    };

    /// <summary>
    /// Build a file tree for the given directory path, up to maxDepth levels.
    /// Returns a JSON-serializable list of entries.
    /// </summary>
    public static List<Dictionary<string, object>> GetFileTree(string rootPath, int maxDepth = 4)
    {
        var results = new List<Dictionary<string, object>>();
        if (!Directory.Exists(rootPath)) return results;

        EnumerateDirectory(rootPath, rootPath, 0, maxDepth, results);
        return results;
    }

    private static void EnumerateDirectory(
        string rootPath, string currentPath, int depth, int maxDepth,
        List<Dictionary<string, object>> results)
    {
        if (depth > maxDepth) return;

        try
        {
            var entries = Directory.EnumerateFileSystemEntries(currentPath)
                .OrderBy(e => !Directory.Exists(e)) // dirs first
                .ThenBy(e => Path.GetFileName(e), StringComparer.OrdinalIgnoreCase);

            foreach (var fullPath in entries)
            {
                var name = Path.GetFileName(fullPath);
                var isDir = Directory.Exists(fullPath);

                if (isDir && SkipDirs.Contains(name))
                    continue;

                // Skip hidden files/dirs (starting with .) except some config files
                if (name.StartsWith('.') && isDir && name != ".github" && name != ".vscode")
                    continue;

                var relativePath = Path.GetRelativePath(rootPath, fullPath).Replace('\\', '/');

                var entry = new Dictionary<string, object>
                {
                    ["name"] = name,
                    ["path"] = relativePath,
                    ["isDirectory"] = isDir,
                };

                if (isDir)
                {
                    var children = new List<Dictionary<string, object>>();
                    EnumerateDirectory(rootPath, fullPath, depth + 1, maxDepth, children);
                    entry["children"] = children;
                }
                else
                {
                    try { entry["size"] = new FileInfo(fullPath).Length; }
                    catch { entry["size"] = 0L; }
                }

                results.Add(entry);
            }
        }
        catch (UnauthorizedAccessException) { /* skip inaccessible dirs */ }
        catch (IOException) { /* skip I/O errors */ }
    }

    /// <summary>
    /// Read a file's contents. Returns null for binary files.
    /// </summary>
    public static (string? content, bool isBinary, long size) ReadFile(string filePath)
    {
        if (!File.Exists(filePath))
            return (null, false, 0);

        var info = new FileInfo(filePath);
        var ext = info.Extension;

        // Check extension-based binary detection
        if (BinaryExtensions.Contains(ext))
            return (null, true, info.Length);

        // Size limit: 1MB for text files
        if (info.Length > 1_048_576)
            return (null, false, info.Length);

        try
        {
            // Read file once, check first 8KB for null bytes, then decode
            var bytes = File.ReadAllBytes(filePath);

            var checkLen = Math.Min(bytes.Length, 8192);
            for (int i = 0; i < checkLen; i++)
            {
                if (bytes[i] == 0)
                    return (null, true, info.Length);
            }

            var content = Encoding.UTF8.GetString(bytes);
            return (content, false, info.Length);
        }
        catch
        {
            return (null, false, info.Length);
        }
    }
}
