using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace TarsyWindows.Assets;

/// <summary>
/// Lucide icon font helper. Loads lucide.ttf via PrivateFontCollection
/// and exposes named icons via Unicode codepoints.
/// </summary>
public static class LucideIcons
{
    private static readonly PrivateFontCollection _fonts = new();
    private static FontFamily? _family;

    static LucideIcons()
    {
        try
        {
            using var stream = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream("TarsyWindows.Assets.lucide.ttf");
            if (stream == null) return;

            var bytes = new byte[stream.Length];
            stream.ReadExactly(bytes);

            var ptr = Marshal.AllocCoTaskMem(bytes.Length);
            try
            {
                Marshal.Copy(bytes, 0, ptr, bytes.Length);
                _fonts.AddMemoryFont(ptr, bytes.Length);
                if (_fonts.Families.Length > 0)
                    _family = _fonts.Families[0];
            }
            finally
            {
                Marshal.FreeCoTaskMem(ptr);
            }
        }
        catch { }
    }

    /// <summary>Whether the font loaded successfully.</summary>
    public static bool Available => _family != null;

    /// <summary>Get a Lucide font at the requested point size.</summary>
    public static Font? GetFont(float sizePt, FontStyle style = FontStyle.Regular)
    {
        if (_family == null) return null;
        try { return new Font(_family, sizePt, style, GraphicsUnit.Point); }
        catch { return null; }
    }

    /// <summary>
    /// Draw a Lucide icon centered in the given rectangle.
    /// </summary>
    public static void Draw(Graphics g, string iconName, Rectangle rect, Color color)
    {
        if (_family == null) return;
        var glyph = GetGlyph(iconName);
        if (glyph == null) return;

        // Compute font size that fits the rect (Lucide icons are designed for the cap-height ~ font size)
        float sizePt = rect.Height * 0.75f;
        using var font = new Font(_family, sizePt, FontStyle.Regular, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(color);

        var oldHint = g.TextRenderingHint;
        var oldSmoothing = g.SmoothingMode;
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        g.SmoothingMode = SmoothingMode.AntiAlias;

        var sf = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
        };
        g.DrawString(glyph, font, brush, rect, sf);

        g.TextRenderingHint = oldHint;
        g.SmoothingMode = oldSmoothing;
    }

    /// <summary>
    /// Draw a Lucide icon at the given top-left position with explicit size.
    /// </summary>
    public static void Draw(Graphics g, string iconName, int x, int y, int size, Color color)
        => Draw(g, iconName, new Rectangle(x, y, size, size), color);

    /// <summary>
    /// Get the Unicode glyph string for a Lucide icon name (e.g. "eye", "mail", "lock").
    /// Returns null if the icon is not in the mapping.
    /// </summary>
    public static string? GetGlyph(string name) => name switch
    {
        // Auth & login
        "eye"            => "\ue0ba",
        "eye-off"        => "\ue0bb",
        "lock"           => "\ue10b",
        "key-round"      => "\ue4a3",
        "mail"           => "\ue10f",
        "user"           => "\ue19f",
        "log-out"        => "\ue10e",
        "arrow-left"     => "\ue048",
        "arrow-right"    => "\ue049",

        // System & status
        "check"          => "\ue06c",
        "x"              => "\ue1b2",
        "circle-check"   => "\ue226",
        "circle-x"       => "\ue084",
        "triangle-alert" => "\ue193",
        "info"           => "\ue0f9",
        "loader"         => "\ue109",
        "refresh-cw"     => "\ue145",
        "power"          => "\ue140",

        // Hardware
        "monitor"        => "\ue11d",
        "laptop"         => "\ue1cd",
        "cpu"            => "\ue0a9",
        "hard-drive"     => "\ue0ed",
        "server"         => "\ue153",
        "network"        => "\ue125",
        "plug"           => "\ue37f",

        // Files & settings
        "folder"         => "\ue0d7",
        "settings"       => "\ue154",
        "download"       => "\ue0b2",

        _ => null,
    };
}
