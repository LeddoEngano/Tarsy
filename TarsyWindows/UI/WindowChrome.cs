using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TarsyWindows.UI;

/// <summary>
/// Customizes the Windows 11 title bar (caption + border) to match the app's dark theme.
/// Falls back silently on Windows 10 / earlier where DWM attributes aren't supported.
/// </summary>
internal static class WindowChrome
{
    // Windows 10 1809+: 19 (older) or 20 (1903+) for immersive dark mode
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
    private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;

    // Windows 11 22000+ only
    private const int DWMWA_BORDER_COLOR = 34;
    private const int DWMWA_CAPTION_COLOR = 35;
    private const int DWMWA_TEXT_COLOR = 36;

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    /// <summary>
    /// Apply a dark title bar. On Windows 11, also sets caption/border/text colors.
    /// On Windows 10, falls back to immersive dark mode (system dark gray title bar).
    /// </summary>
    public static void ApplyDarkTitleBar(Form form, Color bgColor, Color textColor)
    {
        if (form.Handle == IntPtr.Zero) return;

        try
        {
            // Enable immersive dark mode — try newer attribute first, fall back to older
            int useDark = 1;
            int hr = DwmSetWindowAttribute(form.Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref useDark, sizeof(int));
            if (hr != 0)
            {
                DwmSetWindowAttribute(form.Handle, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, ref useDark, sizeof(int));
            }

            // Try Windows 11 custom colors (will silently no-op on Windows 10)
            int caption = ToBgr(bgColor);
            DwmSetWindowAttribute(form.Handle, DWMWA_CAPTION_COLOR, ref caption, sizeof(int));

            int border = ToBgr(bgColor);
            DwmSetWindowAttribute(form.Handle, DWMWA_BORDER_COLOR, ref border, sizeof(int));

            int text = ToBgr(textColor);
            DwmSetWindowAttribute(form.Handle, DWMWA_TEXT_COLOR, ref text, sizeof(int));
        }
        catch
        {
            // Silently ignore on unsupported Windows versions
        }
    }

    private static int ToBgr(Color c) => (c.B << 16) | (c.G << 8) | c.R;
}
