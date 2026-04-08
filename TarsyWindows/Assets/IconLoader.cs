using System;
using System.Collections.Generic;
using System.Drawing;
using System.Reflection;

namespace TarsyWindows.Assets;

/// <summary>
/// Loads embedded PNG icons from Assets/Icons/.
/// Resource names follow: TarsyWindows.Assets.Icons.{filename}.png
/// </summary>
public static class IconLoader
{
    private static readonly Dictionary<string, Image?> _cache = new();
    private static readonly Assembly _asm = Assembly.GetExecutingAssembly();
    private const string Prefix = "TarsyWindows.Assets.Icons.";

    /// <summary>
    /// Load an icon by filename (e.g. "github-icon" loads github-icon.png).
    /// Returns null if not found. Results are cached.
    /// </summary>
    public static Image? Get(string name)
    {
        if (_cache.TryGetValue(name, out var cached)) return cached;

        Image? img = null;
        try
        {
            var resourceName = $"{Prefix}{name}.png";
            using var stream = _asm.GetManifestResourceStream(resourceName);
            if (stream != null) img = Image.FromStream(stream);
        }
        catch { }

        _cache[name] = img;
        return img;
    }

    // ── Convenience accessors ──

    public static Image? Apple => Get("apple-logo");
    public static Image? TarsyLogo => Get("tarsy-logo");
    public static Image? AppIcon => Get("app-icon");
    public static Image? GitHub => Get("github-icon");
    public static Image? Claude => Get("cc-icon");
    public static Image? Gemini => Get("gemini-icon");
    public static Image? Codex => Get("codex-icon");
    public static Image? Aider => Get("aider-logo");
    public static Image? Copilot => Get("copilot-icon");
    public static Image? Cursor => Get("cursor-icon");
    public static Image? Cline => Get("cline-icon");
    public static Image? Windsurf => Get("windsurf-icon");
    public static Image? Amp => Get("amp-icon");
}
