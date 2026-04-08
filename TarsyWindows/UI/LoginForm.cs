using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;
using TarsyWindows.Assets;

namespace TarsyWindows.UI;

/// <summary>
/// Dark-themed login form matching TarsymacOS OnboardingWindow design.
/// All layout is owner-drawn with precise pixel positioning.
/// </summary>
public class LoginForm : Form
{
    private TextBox _emailBox = null!;
    private TextBox _passwordBox = null!;
    private Panel _signInButton = null!;
    private Label _signInLabel = null!;
    private Label _statusLabel = null!;
    private Panel _emailFormPanel = null!;
    private Panel _oauthPanel = null!;
    private Panel _backButton = null!;
    private Panel _contentPanel = null!;

    // ── Theme (matches TarsymacOS OnboardingWindow.swift) ──
    private static readonly Color BgPrimary = ColorTranslator.FromHtml("#131316");
    private static readonly Color BgCard = ColorTranslator.FromHtml("#1c1c21");
    private static readonly Color BgInput = ColorTranslator.FromHtml("#18181c");
    private static readonly Color BorderColor = ColorTranslator.FromHtml("#2a2a30");
    private static readonly Color TextPrimary = ColorTranslator.FromHtml("#e4e4e7");
    private static readonly Color TextSecondary = ColorTranslator.FromHtml("#71717a");
    private static readonly Color TextMuted = ColorTranslator.FromHtml("#52525b");
    private static readonly Color AccentWhite = ColorTranslator.FromHtml("#ffffff");
    private static readonly Color ErrorColor = ColorTranslator.FromHtml("#e5716a");

    // ── Layout constants ──
    private const int FormW = 500;
    private const int FormH = 560;
    private const int HeaderH = 56;
    private const int BtnW = 320;
    private const int BtnH = 42;
    private const int BtnGap = 12;
    private const int InputH = 46;
    private const int InputGap = 14;
    private const int LogoSize = 48;

    private Image? _logoImage;

    private static Font Mono(float size, FontStyle style = FontStyle.Regular)
        => new("Cascadia Code", size, style);

    public string Email => _emailBox.Text.Trim();
    public string Password => _passwordBox.Text;
    public event EventHandler? SignInClicked;
    public event EventHandler? GitHubSignInClicked;

    public LoginForm()
    {
        LoadAssets();
        InitializeForm();
        BuildUI();
    }

    private void LoadAssets()
    {
        _logoImage = IconLoader.TarsyLogo;

        try
        {
            var appIcon = IconLoader.AppIcon;
            if (appIcon != null)
            {
                using var bmp = new Bitmap(appIcon);
                Icon = Icon.FromHandle(bmp.GetHicon());
            }
        }
        catch { }
    }

    private void InitializeForm()
    {
        Text = "Tarsy";
        ClientSize = new Size(FormW, FormH);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = BgPrimary;
        ForeColor = TextPrimary;
        DoubleBuffered = true;
    }

    // ═══════════════════════════════════════════
    //  BUILD
    // ═══════════════════════════════════════════

    private void BuildUI()
    {
        // ── Header ──
        var header = new Panel { Dock = DockStyle.Top, Height = HeaderH, BackColor = BgPrimary };
        header.Paint += PaintHeader;

        // ── Content ──
        _contentPanel = new Panel { Dock = DockStyle.Fill, BackColor = BgPrimary };

        // Logo
        var logo = new PictureBox
        {
            Size = new Size(LogoSize, LogoSize),
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Color.Transparent,
            Image = _logoImage,
        };

        // Heading + subheading
        var heading = new Label
        {
            Text = "welcome to tarsy",
            Font = Mono(16f, FontStyle.Bold),
            ForeColor = TextPrimary,
            AutoSize = true,
            BackColor = Color.Transparent,
        };
        var subheading = new Label
        {
            Text = "sign in to connect your devices",
            Font = Mono(10f),
            ForeColor = TextSecondary,
            AutoSize = true,
            BackColor = Color.Transparent,
        };

        // ── OAuth panel (2 buttons × 42px + 1 gap × 12px = 96px) ──
        int oauthH = 2 * BtnH + BtnGap;
        _oauthPanel = new Panel { Size = new Size(BtnW, oauthH), BackColor = BgPrimary, Visible = true };

        var githubBtn = MakeOAuthButton("Sign in with GitHub", 0, () => GitHubSignInClicked?.Invoke(this, EventArgs.Empty), DrawGitHubIcon);
        var emailBtn = MakeOAuthButton("Sign in with Email", BtnH + BtnGap, () => ShowEmailForm(), DrawEmailIcon);

        _oauthPanel.Controls.AddRange(new Control[] { githubBtn, emailBtn });

        // ── Email form panel ──
        // back(24) + 10 + email(46) + 14 + password(46) + 20 + status(18) + 8 + button(42) = 228
        int emailH = 24 + 10 + InputH + InputGap + InputH + 20 + 18 + 8 + BtnH;
        _emailFormPanel = new Panel { Size = new Size(BtnW, emailH), BackColor = BgPrimary, Visible = false };

        int ey = 0;
        _backButton = MakeBackButton();
        _backButton.Location = new Point(0, ey);
        ey += 24 + 10;

        var emailField = MakeInputField("email", false, out _emailBox);
        emailField.Location = new Point(0, ey);
        ey += InputH + InputGap;

        var passField = MakeInputField("password", true, out _passwordBox);
        passField.Location = new Point(0, ey);
        ey += InputH + 20;

        _statusLabel = new Label
        {
            Size = new Size(BtnW, 18),
            Location = new Point(0, ey),
            Font = Mono(9f),
            ForeColor = TextSecondary,
            TextAlign = ContentAlignment.MiddleCenter,
            BackColor = BgPrimary,
        };
        ey += 18 + 8;

        _signInButton = new Panel { Size = new Size(BtnW, BtnH), Location = new Point(0, ey), BackColor = BgPrimary, Cursor = Cursors.Hand };
        _signInLabel = new Label
        {
            Text = "sign in",
            Font = Mono(11f, FontStyle.Bold),
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            ForeColor = BgPrimary,
            Cursor = Cursors.Hand,
        };
        _signInButton.Controls.Add(_signInLabel);
        _signInButton.Paint += PaintButton;
        _signInButton.Click += (_, _) => OnSignIn();
        _signInLabel.Click += (_, _) => OnSignIn();

        _emailFormPanel.Controls.AddRange(new Control[] { _backButton, emailField, passField, _statusLabel, _signInButton });

        // Key shortcuts
        _passwordBox.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; OnSignIn(); } };
        _emailBox.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; _passwordBox.Focus(); } };

        // ── Footer ──
        var footer = MakeFooter();

        // ── Add to content ──
        _contentPanel.Controls.AddRange(new Control[] { logo, heading, subheading, _oauthPanel, _emailFormPanel, footer });

        // Layout handler
        _contentPanel.Resize += (_, _) => DoLayout(logo, heading, subheading, footer);
        _contentPanel.Layout += (_, _) => DoLayout(logo, heading, subheading, footer);

        // Add to form (header must be added last to dock on top)
        Controls.Add(_contentPanel);
        Controls.Add(header);
    }

    // ═══════════════════════════════════════════
    //  LAYOUT — pixel-perfect centering
    // ═══════════════════════════════════════════

    private void DoLayout(PictureBox logo, Label heading, Label subheading, Control footer)
    {
        int cw = _contentPanel.ClientSize.Width;
        int ch = _contentPanel.ClientSize.Height;
        int cx = cw / 2; // horizontal center

        // Active panel height
        var activePanel = _oauthPanel.Visible ? _oauthPanel : _emailFormPanel;
        int panelH = activePanel.Height;

        // Total content block height
        //   logo(48) + gap(20) + heading + gap(8) + subheading + gap(36) + panel
        int totalH = LogoSize + 20 + heading.Height + 8 + subheading.Height + 36 + panelH;

        // Center vertically in available space (leave 40px for footer)
        int startY = Math.Max(16, (ch - 40 - totalH) / 2);

        // Place each element
        int y = startY;

        logo.Location = new Point(cx - LogoSize / 2, y);
        y += LogoSize + 20;

        heading.Location = new Point(cx - heading.Width / 2, y);
        y += heading.Height + 8;

        subheading.Location = new Point(cx - subheading.Width / 2, y);
        y += subheading.Height + 36;

        _oauthPanel.Location = new Point(cx - BtnW / 2, y);
        _emailFormPanel.Location = new Point(cx - BtnW / 2, y);

        // Footer pinned to bottom
        footer.Location = new Point(cx - footer.Width / 2, ch - 32);
    }

    // ═══════════════════════════════════════════
    //  HEADER
    // ═══════════════════════════════════════════

    private void PaintHeader(object? sender, PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAlias;
        int w = ((Panel)sender!).Width;

        // Divider at bottom
        using var divPen = new Pen(BorderColor);
        g.DrawLine(divPen, 0, HeaderH - 1, w, HeaderH - 1);

        // Measure "tarsy" to center logo+text as a unit
        using var titleFont = Mono(14f, FontStyle.Bold);
        var textSize = g.MeasureString("tarsy", titleFont);
        int logoSz = 24;
        int gap = 10;
        int unitW = logoSz + gap + (int)Math.Ceiling(textSize.Width);
        int startX = (w - unitW) / 2;
        int logoY = (HeaderH - 1 - logoSz) / 2;

        // Logo
        if (_logoImage != null)
        {
            var lr = new Rectangle(startX, logoY, logoSz, logoSz);
            var clip = RoundedRect(lr, 5);
            g.SetClip(clip);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(_logoImage, lr);
            g.ResetClip();
        }
        else
        {
            var lr = new Rectangle(startX, logoY, logoSz, logoSz);
            using var b = new SolidBrush(AccentWhite);
            g.FillPath(b, RoundedRect(lr, 5));
            using var f = Mono(11f, FontStyle.Bold);
            using var tb = new SolidBrush(BgPrimary);
            var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("T", f, tb, lr, sf);
        }

        // "tarsy"
        int textY = (HeaderH - 1 - (int)textSize.Height) / 2;
        using var titleBrush = new SolidBrush(TextPrimary);
        g.DrawString("tarsy", titleFont, titleBrush, startX + logoSz + gap, textY);
    }

    // ═══════════════════════════════════════════
    //  OAUTH BUTTONS
    // ═══════════════════════════════════════════

    private Panel MakeOAuthButton(string text, int y, Action? onClick, Action<Graphics, Rectangle, bool> drawIcon)
    {
        var btn = new Panel
        {
            Size = new Size(BtnW, BtnH),
            Location = new Point(0, y),
            BackColor = BgPrimary,
            Cursor = Cursors.Hand,
        };

        var lbl = new Label
        {
            Text = text,
            Font = Mono(11f, FontStyle.Bold),
            ForeColor = AccentWhite,
            BackColor = Color.Transparent,
            Cursor = Cursors.Hand,
            // Text area: starts after icon area, centered in remaining space
            Location = new Point(0, 0),
            Size = new Size(BtnW, BtnH),
            TextAlign = ContentAlignment.MiddleCenter,
            // Shift text right by half icon area to optically center icon+text
            Padding = new Padding(20, 0, 0, 0),
        };

        bool hover = false;

        btn.Paint += (_, e) =>
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, BtnW - 1, BtnH - 1);
            var path = RoundedRect(r, 8);

            using var bg = new SolidBrush(BgCard);
            g.FillPath(bg, path);

            int alpha = hover && btn.Enabled ? 128 : 38;
            using var border = new Pen(Color.FromArgb(alpha, 255, 255, 255));
            g.DrawPath(border, path);

            // Icon: 18x18, vertically centered, 16px from left edge
            var iconR = new Rectangle(16, (BtnH - 18) / 2, 18, 18);
            drawIcon(g, iconR, btn.Enabled);
        };

        void SetH(bool h) { hover = h; btn.Invalidate(); }
        btn.MouseEnter += (_, _) => SetH(true);
        btn.MouseLeave += (_, _) => SetH(false);
        lbl.MouseEnter += (_, _) => SetH(true);
        lbl.MouseLeave += (_, _) => SetH(false);
        btn.Click += (_, _) => onClick?.Invoke();
        lbl.Click += (_, _) => onClick?.Invoke();

        btn.Controls.Add(lbl);
        return btn;
    }

    // ═══════════════════════════════════════════
    //  ICON RENDERERS
    // ═══════════════════════════════════════════

    private static void DrawGitHubIcon(Graphics g, Rectangle r, bool enabled)
    {
        var img = IconLoader.GitHub;
        if (img != null)
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            if (!enabled)
            {
                // Draw dimmed
                using var attrs = new System.Drawing.Imaging.ImageAttributes();
                var cm = new System.Drawing.Imaging.ColorMatrix { Matrix33 = 0.4f };
                attrs.SetColorMatrix(cm);
                g.DrawImage(img, r, 0, 0, img.Width, img.Height, GraphicsUnit.Pixel, attrs);
            }
            else
            {
                g.DrawImage(img, r);
            }
            return;
        }

        // Fallback: simple circle
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var brush = new SolidBrush(enabled ? AccentWhite : TextMuted);
        g.FillEllipse(brush, r);
    }

    private static void DrawEmailIcon(Graphics g, Rectangle r, bool enabled)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        var c = enabled ? AccentWhite : TextMuted;

        // Envelope
        int pad = 2;
        var env = new Rectangle(r.X + pad, r.Y + pad + 2, r.Width - pad * 2, r.Height - pad * 2 - 4);
        using var pen = new Pen(c, 1.5f) { LineJoin = LineJoin.Round };

        g.DrawPath(pen, RoundedRect(env, 2));
        // Flap
        g.DrawLine(pen, env.Left + 2, env.Top + 2, env.Left + env.Width / 2, env.Top + env.Height / 2 - 1);
        g.DrawLine(pen, env.Left + env.Width / 2, env.Top + env.Height / 2 - 1, env.Right - 2, env.Top + 2);
    }

    // ═══════════════════════════════════════════
    //  INPUT FIELDS
    // ═══════════════════════════════════════════

    private Panel MakeInputField(string placeholder, bool isPassword, out TextBox textBox)
    {
        var container = new Panel
        {
            Size = new Size(BtnW, InputH),
            BackColor = BgPrimary,
        };

        container.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, BtnW - 1, InputH - 1);
            using var bg = new SolidBrush(BgInput);
            e.Graphics.FillPath(bg, RoundedRect(r, 8));
            using var border = new Pen(BorderColor);
            e.Graphics.DrawPath(border, RoundedRect(r, 8));
        };

        // Draw icon via paint instead of emoji label
        container.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var pen = new Pen(TextMuted, 1.2f) { LineJoin = LineJoin.Round };
            int ix = 14, iy = (InputH - 14) / 2, isz = 14;

            if (isPassword)
            {
                // Lock icon
                var bodyR = new Rectangle(ix, iy + 5, isz, isz - 5);
                e.Graphics.DrawPath(pen, RoundedRect(bodyR, 2));
                e.Graphics.DrawArc(pen, ix + 2, iy, isz - 4, 10, 180, 180);
            }
            else
            {
                // Envelope icon (small)
                var envR = new Rectangle(ix, iy + 2, isz, isz - 4);
                e.Graphics.DrawRectangle(pen, envR);
                e.Graphics.DrawLine(pen, envR.Left + 1, envR.Top + 1, envR.Left + envR.Width / 2, envR.Top + envR.Height / 2);
                e.Graphics.DrawLine(pen, envR.Left + envR.Width / 2, envR.Top + envR.Height / 2, envR.Right - 1, envR.Top + 1);
            }
        };

        textBox = new TextBox
        {
            Font = Mono(10.5f),
            ForeColor = TextPrimary,
            BackColor = BgInput,
            BorderStyle = BorderStyle.None,
            Size = new Size(BtnW - 52, 20),
            Location = new Point(38, (InputH - 20) / 2),
            UseSystemPasswordChar = isPassword,
        };

        // Placeholder
        var tb = textBox;
        bool hasPlaceholder = true;
        tb.Text = placeholder;
        tb.ForeColor = TextMuted;
        if (isPassword) tb.UseSystemPasswordChar = false;

        tb.GotFocus += (_, _) =>
        {
            if (!hasPlaceholder) return;
            tb.Text = "";
            tb.ForeColor = TextPrimary;
            if (isPassword) tb.UseSystemPasswordChar = true;
            hasPlaceholder = false;
        };
        tb.LostFocus += (_, _) =>
        {
            if (!string.IsNullOrEmpty(tb.Text)) return;
            hasPlaceholder = true;
            if (isPassword) tb.UseSystemPasswordChar = false;
            tb.Text = placeholder;
            tb.ForeColor = TextMuted;
        };

        container.Controls.Add(tb);
        return container;
    }

    // ═══════════════════════════════════════════
    //  MISC UI ELEMENTS
    // ═══════════════════════════════════════════

    private Panel MakeBackButton()
    {
        var btn = new Panel { Size = new Size(70, 24), BackColor = BgPrimary, Cursor = Cursors.Hand };
        btn.Paint += (_, e) =>
        {
            e.Graphics.TextRenderingHint = TextRenderingHint.AntiAlias;
            using var f = Mono(9f);
            using var b = new SolidBrush(TextMuted);
            e.Graphics.DrawString("\u2190 back", f, b, 0, 5);
        };
        btn.Click += (_, _) => ShowOAuthPanel();
        return btn;
    }

    private void PaintButton(object? sender, PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var r = new Rectangle(0, 0, BtnW - 1, BtnH - 1);
        using var brush = new SolidBrush(_signInButton.Enabled ? AccentWhite : TextMuted);
        e.Graphics.FillPath(brush, RoundedRect(r, 8));
    }

    private static Control MakeFooter()
    {
        var panel = new FlowLayoutPanel
        {
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            WrapContents = false,
            BackColor = BgPrimary,
            Padding = Padding.Empty,
            Margin = Padding.Empty,
        };

        panel.Controls.Add(FooterText("by signing in, you agree to our "));
        panel.Controls.Add(FooterLink("terms", "https://www.tarsy.dev/terms"));
        panel.Controls.Add(FooterText(" and "));
        panel.Controls.Add(FooterLink("privacy policy", "https://www.tarsy.dev/privacy"));
        return panel;
    }

    private static Label FooterText(string text) => new()
    {
        Text = text,
        Font = Mono(8f),
        ForeColor = TextMuted,
        AutoSize = true,
        BackColor = BgPrimary,
        Margin = new Padding(0, 3, 0, 0),
        Padding = Padding.Empty,
    };

    private static LinkLabel FooterLink(string text, string url)
    {
        var link = new LinkLabel
        {
            Text = text,
            Font = Mono(8f),
            LinkColor = TextSecondary,
            ActiveLinkColor = AccentWhite,
            VisitedLinkColor = TextSecondary,
            AutoSize = true,
            BackColor = BgPrimary,
            Margin = new Padding(0, 3, 0, 0),
            Padding = Padding.Empty,
            Cursor = Cursors.Hand,
            LinkBehavior = LinkBehavior.HoverUnderline,
        };
        link.LinkClicked += (_, _) =>
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
            catch { }
        };
        return link;
    }

    // ═══════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════

    private void ShowEmailForm()
    {
        _oauthPanel.Visible = false;
        _emailFormPanel.Visible = true;
        _contentPanel.PerformLayout();
        _emailBox.Focus();
    }

    private void ShowOAuthPanel()
    {
        _emailFormPanel.Visible = false;
        _oauthPanel.Visible = true;
        _contentPanel.PerformLayout();
    }

    private void OnSignIn()
    {
        if (!_signInButton.Enabled) return;
        SignInClicked?.Invoke(this, EventArgs.Empty);
    }

    public void SetStatus(string message)
    {
        if (InvokeRequired) { Invoke(() => SetStatus(message)); return; }
        _statusLabel.ForeColor = TextSecondary;
        _statusLabel.Text = message;
    }

    public void SetError(string message)
    {
        if (InvokeRequired) { Invoke(() => SetError(message)); return; }
        _statusLabel.ForeColor = ErrorColor;
        _statusLabel.Text = message;
    }

    public void SetLoading(bool loading)
    {
        if (InvokeRequired) { Invoke(() => SetLoading(loading)); return; }
        _signInButton.Enabled = !loading;
        _signInLabel.Text = loading ? "signing in..." : "sign in";
        _signInButton.Invalidate();
        _emailBox.Enabled = !loading;
        _passwordBox.Enabled = !loading;
        _backButton.Enabled = !loading;
    }

    // ═══════════════════════════════════════════
    //  UTIL
    // ═══════════════════════════════════════════

    private static GraphicsPath RoundedRect(Rectangle bounds, int radius)
    {
        int d = radius * 2;
        var p = new GraphicsPath();
        p.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
        p.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        p.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        p.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}
