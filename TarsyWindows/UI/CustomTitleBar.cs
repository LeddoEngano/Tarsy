using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace TarsyWindows.UI;

/// <summary>
/// A custom title bar that replaces the native Windows chrome.
/// Provides dragging, close button, and consistent dark theme colors.
/// </summary>
internal class CustomTitleBar : Panel
{
    private const int WM_NCLBUTTONDOWN = 0xA1;
    private const int HT_CAPTION = 0x2;

    [DllImport("user32.dll")]
    private static extern int SendMessage(IntPtr hWnd, int msg, int wParam, int lParam);

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    private static readonly Color BgColor = ColorTranslator.FromHtml("#0a0a0a");
    private static readonly Color TextColor = ColorTranslator.FromHtml("#71717a");
    private static readonly Color HoverColor = ColorTranslator.FromHtml("#1e1e22");
    private static readonly Color CloseHoverColor = ColorTranslator.FromHtml("#e5716a");

    private readonly Form _parent;
    private readonly string _title;
    private bool _closeHover;
    private Rectangle _closeRect;

    public CustomTitleBar(Form parent, string title)
    {
        _parent = parent;
        _title = title;
        Dock = DockStyle.Top;
        Height = 32;
        BackColor = BgColor;
        DoubleBuffered = true;

        MouseDown += OnMouseDown;
        MouseMove += OnMouseMove;
        MouseLeave += (_, _) => { _closeHover = false; Invalidate(); };
        MouseClick += OnMouseClick;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;

        // Background
        using var bg = new SolidBrush(BgColor);
        g.FillRectangle(bg, ClientRectangle);

        // Title text (left-aligned, padded)
        using var font = new Font("Cascadia Code", 8.25f, FontStyle.Regular);
        using var textBrush = new SolidBrush(TextColor);
        var textSize = g.MeasureString(_title, font);
        float ty = (Height - textSize.Height) / 2f;
        g.DrawString(_title, font, textBrush, 12, ty);

        // Close button (right side, 46x32, like Windows)
        int btnW = 46;
        _closeRect = new Rectangle(Width - btnW, 0, btnW, Height);

        if (_closeHover)
        {
            using var hb = new SolidBrush(CloseHoverColor);
            g.FillRectangle(hb, _closeRect);
        }

        // Draw X
        using var xPen = new Pen(_closeHover ? Color.White : TextColor, 1.2f);
        int cx = _closeRect.X + btnW / 2;
        int cy = Height / 2;
        int s = 5;
        g.DrawLine(xPen, cx - s, cy - s, cx + s, cy + s);
        g.DrawLine(xPen, cx + s, cy - s, cx - s, cy + s);

        // Bottom divider
        using var divPen = new Pen(ColorTranslator.FromHtml("#1c1c20"));
        g.DrawLine(divPen, 0, Height - 1, Width, Height - 1);
    }

    private void OnMouseDown(object? sender, MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        if (_closeRect.Contains(e.Location)) return;

        // Drag the window via NCLBUTTONDOWN
        ReleaseCapture();
        SendMessage(_parent.Handle, WM_NCLBUTTONDOWN, HT_CAPTION, 0);
    }

    private void OnMouseMove(object? sender, MouseEventArgs e)
    {
        bool wasHover = _closeHover;
        _closeHover = _closeRect.Contains(e.Location);
        if (wasHover != _closeHover) Invalidate();
        Cursor = _closeHover ? Cursors.Hand : Cursors.Default;
    }

    private void OnMouseClick(object? sender, MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left && _closeRect.Contains(e.Location))
        {
            _parent.Close();
        }
    }
}
