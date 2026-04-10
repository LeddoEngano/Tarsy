using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Windows.Forms;
using TarsyWindows.Assets;

namespace TarsyWindows.UI;

/// <summary>
/// Dark-themed login form matching Tarsy design system.
/// All layout is owner-drawn with precise pixel positioning on an 8px grid.
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

    // Track OAuth button panels for SetLoading
    private Panel _githubBtn = null!;
    private Panel _emailBtn = null!;

    // ── Theme ──
    private static readonly Color BgPrimary = ColorTranslator.FromHtml("#0a0a0a");
    private static readonly Color BgCard = ColorTranslator.FromHtml("#141417");
    private static readonly Color BgInput = ColorTranslator.FromHtml("#18181c");
    private static readonly Color BorderColor = ColorTranslator.FromHtml("#2a2a30");
    private static readonly Color TextPrimary = ColorTranslator.FromHtml("#e4e4e7");
    private static readonly Color TextSecondary = ColorTranslator.FromHtml("#71717a");
    private static readonly Color TextMuted = ColorTranslator.FromHtml("#52525b");
    private static readonly Color AccentWhite = ColorTranslator.FromHtml("#ffffff");
    private static readonly Color ErrorColor = ColorTranslator.FromHtml("#e5716a");

    // Hover step colors
    private static readonly Color BgCardHover = ColorTranslator.FromHtml("#1c1c20");
    private static readonly Color BgInputFocus = ColorTranslator.FromHtml("#1e1e24");

    // ── Layout constants (8px grid) ──
    private const int FormW = 460;
    private const int FormH = 540;
    private const int HeaderH = 52;
    private const int PagePad = 32;
    private const int CardPad = 24;
    private const int BtnW = 320;
    private const int BtnH = 40;
    private const int BtnRadius = 8;
    private const int InputH = 40;
    private const int InputRadius = 6;
    private const int ElementGap = 16;
    private const int LogoSize = 48;
    private const int HeaderLogoSize = 24;

    private Image? _logoImage;
    private AnimatedLogo? _animatedLogo;

    private static Font Mono(float size, FontStyle style = FontStyle.Regular)
        => new("Cascadia Code", size, style);

    // ── Public API ──
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
        ClientSize = new Size(FormW, FormH + 32); // +32 for custom title bar
        FormBorderStyle = FormBorderStyle.None;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = BgPrimary;
        ForeColor = TextPrimary;
        DoubleBuffered = true;

        // Custom title bar replaces native chrome
        Controls.Add(new CustomTitleBar(this, "tarsy"));
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        _animatedLogo?.Play();
    }

    // ═══════════════════════════════════════════
    //  BUILD
    // ═══════════════════════════════════════════

    private void BuildUI()
    {
        // ── Content positioned below the custom title bar (32px) ──
        _contentPanel = new Panel
        {
            BackColor = BgPrimary,
            Location = new Point(0, 32),
            Size = new Size(FormW, FormH),
        };

        // Logo (48x48) — animated entrance
        var logo = new AnimatedLogo(_logoImage, LogoSize);
        _animatedLogo = logo;

        // "welcome to tarsy" — 20px Bold
        var heading = new Label
        {
            Text = "welcome to tarsy",
            Font = Mono(15f, FontStyle.Bold), // 15pt ~= 20px
            ForeColor = TextPrimary,
            AutoSize = true,
            BackColor = Color.Transparent,
        };

        // "sign in to connect your devices" — 12px Regular
        var subheading = new Label
        {
            Text = "sign in to connect your devices",
            Font = Mono(9f), // 9pt ~= 12px
            ForeColor = TextSecondary,
            AutoSize = true,
            BackColor = Color.Transparent,
        };

        // ── OAuth panel (2 buttons x 40px + 12px gap = 92px) ──
        int oauthH = 2 * BtnH + 12;
        _oauthPanel = new Panel { Size = new Size(BtnW, oauthH), BackColor = BgPrimary, Visible = true };

        _githubBtn = MakeOAuthButton("Sign in with GitHub", 0,
            () => GitHubSignInClicked?.Invoke(this, EventArgs.Empty), DrawGitHubIcon);
        _emailBtn = MakeOAuthButton("Sign in with Email", BtnH + 12,
            () => ShowEmailForm(), DrawEmailIcon);

        _oauthPanel.Controls.AddRange(new Control[] { _githubBtn, _emailBtn });

        // ── Email form panel ──
        // back(20) + 6 + email(40) + 12 + password(40) + 10 + status(14) + 10 + button(40) = 192
        int emailH = 20 + 6 + InputH + 12 + InputH + 10 + 14 + 10 + BtnH;
        _emailFormPanel = new Panel { Size = new Size(BtnW, emailH), BackColor = BgPrimary, Visible = false };

        int ey = 0;
        _backButton = MakeBackButton();
        _backButton.Location = new Point(0, ey);
        ey += 20 + 6;

        var emailField = MakeInputField("email", false, out _emailBox);
        emailField.Location = new Point(0, ey);
        ey += InputH + 12;

        var passField = MakeInputField("password", true, out _passwordBox);
        passField.Location = new Point(0, ey);
        ey += InputH + 10;

        _statusLabel = new Label
        {
            Size = new Size(BtnW, 14),
            Location = new Point(0, ey),
            Font = Mono(8.25f), // 11px caption
            ForeColor = TextSecondary,
            TextAlign = ContentAlignment.MiddleCenter,
            BackColor = BgPrimary,
        };
        ey += 14 + 10;

        _signInButton = new Panel
        {
            Size = new Size(BtnW, BtnH),
            Location = new Point(0, ey),
            BackColor = BgPrimary,
            Cursor = Cursors.Hand,
        };
        // Hidden label kept ONLY so SetLoading can change its Text — text is drawn in Paint
        _signInLabel = new Label { Text = "sign in", Visible = false };

        bool signInHover = false;
        _signInButton.Paint += (_, e) => PaintPrimaryButton(e.Graphics, _signInButton, signInHover);
        _signInButton.Click += (_, _) => OnSignIn();
        _signInButton.MouseEnter += (_, _) => { signInHover = true; _signInButton.Invalidate(); };
        _signInButton.MouseLeave += (_, _) => { signInHover = false; _signInButton.Invalidate(); };

        _emailFormPanel.Controls.AddRange(new Control[]
            { _backButton, emailField, passField, _statusLabel, _signInButton });

        // Key shortcuts
        _passwordBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; OnSignIn(); }
        };
        _emailBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; _passwordBox.Focus(); }
        };

        // ── Footer ──
        var footer = MakeFooter();

        // ── Add to content ──
        _contentPanel.Controls.AddRange(new Control[]
            { logo, heading, subheading, _oauthPanel, _emailFormPanel, footer });

        // Layout handler
        _contentPanel.Resize += (_, _) => DoLayout(logo, heading, subheading, footer);
        _contentPanel.Layout += (_, _) => DoLayout(logo, heading, subheading, footer);

        // Add to form (header added last so Dock.Top works)
        Controls.Add(_contentPanel);
    }

    // ═══════════════════════════════════════════
    //  LAYOUT
    // ═══════════════════════════════════════════

    private void DoLayout(Control logo, Label heading, Label subheading, Control footer)
    {
        int cw = _contentPanel.ClientSize.Width;
        int ch = _contentPanel.ClientSize.Height;
        int cx = cw / 2;

        var activePanel = _oauthPanel.Visible ? _oauthPanel : _emailFormPanel;
        int panelH = activePanel.Height;


        // logo(48) + 24 + heading + 8 + subheading + 32 + panel
        int totalH = LogoSize + 24 + heading.Height + 8 + subheading.Height + 32 + panelH;

        // Center vertically, reserving 40px for footer
        int startY = Math.Max(16, (ch - 40 - totalH) / 2);

        int y = startY;

        logo.Location = new Point(cx - LogoSize / 2, y);
        y += LogoSize + 24;

        heading.Location = new Point(cx - heading.Width / 2, y);
        y += heading.Height + 8;

        subheading.Location = new Point(cx - subheading.Width / 2, y);
        y += subheading.Height + 32;

        _oauthPanel.Location = new Point(cx - BtnW / 2, y);
        _emailFormPanel.Location = new Point(cx - BtnW / 2, y);

        // Footer pinned to bottom
        footer.Location = new Point(cx - footer.Width / 2, ch - 28);
    }

    // ═══════════════════════════════════════════
    //  HEADER
    // ═══════════════════════════════════════════

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
            Font = Mono(10f, FontStyle.Bold), // 13px SemiBold
            ForeColor = AccentWhite,
            BackColor = Color.Transparent,
            Cursor = Cursors.Hand,
            Location = new Point(0, 0),
            Size = new Size(BtnW, BtnH),
            TextAlign = ContentAlignment.MiddleCenter,
            Padding = new Padding(18, 0, 0, 0), // offset for icon
        };

        bool hover = false;

        btn.Paint += (_, e) =>
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            var r = new Rectangle(0, 0, BtnW - 1, BtnH - 1);
            var path = RoundedRect(r, BtnRadius);

            // Fill
            using var bg = new SolidBrush(hover && btn.Enabled ? BgCardHover : BgCard);
            g.FillPath(bg, path);

            // Border
            using var border = new Pen(hover && btn.Enabled
                ? Color.FromArgb(100, 255, 255, 255)
                : BorderColor);
            g.DrawPath(border, path);

            // Icon: 18x18, vertically centered, 16px from left
            var iconR = new Rectangle(16, (BtnH - 18) / 2, 18, 18);
            drawIcon(g, iconR, btn.Enabled);
        };

        void SetH(bool h) { hover = h; btn.Invalidate(); }
        btn.MouseEnter += (_, _) => SetH(true);
        btn.MouseLeave += (_, _) => SetH(false);
        lbl.MouseEnter += (_, _) => SetH(true);
        lbl.MouseLeave += (_, _) => SetH(false);
        btn.Click += (_, _) => { if (btn.Enabled) onClick?.Invoke(); };
        lbl.Click += (_, _) => { if (btn.Enabled) onClick?.Invoke(); };

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

        // Fallback: circle
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var brush = new SolidBrush(enabled ? AccentWhite : TextMuted);
        g.FillEllipse(brush, r);
    }

    private static void DrawEmailIcon(Graphics g, Rectangle r, bool enabled)
    {
        var c = enabled ? AccentWhite : TextMuted;
        LucideIcons.Draw(g, "mail", r, c);
    }

    // ═══════════════════════════════════════════
    //  PRIMARY BUTTON PAINTER
    // ═══════════════════════════════════════════

    private void PaintPrimaryButton(Graphics g, Panel btn, bool hover)
    {
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
        var r = new Rectangle(0, 0, BtnW - 1, BtnH - 1);

        // Background
        Color fill = btn.Enabled
            ? (hover ? Color.FromArgb(230, 230, 230) : AccentWhite)
            : TextMuted;
        using (var brush = new SolidBrush(fill))
            g.FillPath(brush, RoundedRect(r, BtnRadius));

        // Text drawn directly on the panel (label is hidden, used only for text storage)
        using var font = Mono(10f, FontStyle.Bold);
        using var textBrush = new SolidBrush(BgPrimary);
        var sf = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center,
        };
        g.DrawString(_signInLabel.Text, font, textBrush, new RectangleF(0, 0, BtnW, BtnH), sf);
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

        bool focused = false;

        // Background + border paint
        container.Paint += (_, e) =>
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            var r = new Rectangle(0, 0, BtnW - 1, InputH - 1);

            using var bg = new SolidBrush(focused ? BgInputFocus : BgInput);
            g.FillPath(bg, RoundedRect(r, InputRadius));

            // Border: 2px accent on focus, 1px border normally
            if (focused)
            {
                using var border = new Pen(AccentWhite, 2f);
                g.DrawPath(border, RoundedRect(r, InputRadius));
            }
            else
            {
                using var border = new Pen(BorderColor);
                g.DrawPath(border, RoundedRect(r, InputRadius));
            }
        };

        // Icon paint (Lucide font)
        container.Paint += (_, e) =>
        {
            var iconRect = new Rectangle(12, (InputH - 18) / 2, 18, 18);
            LucideIcons.Draw(e.Graphics, isPassword ? "lock" : "mail", iconRect, TextMuted);
        };

        // Reserve room on the right for the eye toggle button when this is a password field
        int rightPad = isPassword ? 44 : 14;

        textBox = new TextBox
        {
            Font = Mono(10f), // 13px
            ForeColor = TextPrimary,
            BackColor = BgInput,
            BorderStyle = BorderStyle.None,
            Size = new Size(BtnW - 38 - rightPad, 18),
            Location = new Point(38, (InputH - 18) / 2),
            UseSystemPasswordChar = isPassword,
            PlaceholderText = placeholder,
        };

        var tb = textBox;
        tb.GotFocus += (_, _) =>
        {
            focused = true;
            tb.BackColor = BgInputFocus;
            container.Invalidate();
        };
        tb.LostFocus += (_, _) =>
        {
            focused = false;
            tb.BackColor = BgInput;
            container.Invalidate();
        };

        container.Controls.Add(tb);
        // Click container to focus textbox
        container.Click += (_, _) => tb.Focus();

        // Show/hide password toggle (eye icon button)
        if (isPassword)
        {
            var toggleBtn = new Panel
            {
                Size = new Size(32, InputH - 8),
                Location = new Point(BtnW - 36, 4),
                BackColor = BgInput,
                Cursor = Cursors.Hand,
            };

            bool showing = false;
            bool hover = false;

            toggleBtn.Paint += (_, e) =>
            {
                var color = hover ? TextPrimary : TextMuted;
                int iconSize = 16;
                int ix = (toggleBtn.Width - iconSize) / 2;
                int iy = (toggleBtn.Height - iconSize) / 2;
                LucideIcons.Draw(e.Graphics, showing ? "eye-off" : "eye",
                    new Rectangle(ix, iy, iconSize, iconSize), color);
            };

            toggleBtn.MouseEnter += (_, _) => { hover = true; toggleBtn.Invalidate(); };
            toggleBtn.MouseLeave += (_, _) => { hover = false; toggleBtn.Invalidate(); };
            toggleBtn.Click += (_, _) =>
            {
                showing = !showing;
                tb.UseSystemPasswordChar = !showing;
                toggleBtn.Invalidate();
                tb.Focus();
            };

            container.Controls.Add(toggleBtn);
            toggleBtn.BringToFront();
        }

        return container;
    }

    // ═══════════════════════════════════════════
    //  MISC UI ELEMENTS
    // ═══════════════════════════════════════════

    private Panel MakeBackButton()
    {
        var btn = new Panel { Size = new Size(80, 22), BackColor = BgPrimary, Cursor = Cursors.Hand };
        var lbl = new Label
        {
            Text = "back",
            Font = Mono(8.25f), // 11px
            ForeColor = TextMuted,
            AutoSize = true,
            BackColor = Color.Transparent,
            Cursor = Cursors.Hand,
            Location = new Point(20, 4),
        };

        bool hover = false;
        void SetH(bool h) { hover = h; lbl.ForeColor = h ? TextSecondary : TextMuted; btn.Invalidate(); }
        btn.MouseEnter += (_, _) => SetH(true);
        btn.MouseLeave += (_, _) => SetH(false);
        lbl.MouseEnter += (_, _) => SetH(true);
        lbl.MouseLeave += (_, _) => SetH(false);
        btn.Click += (_, _) => ShowOAuthPanel();
        lbl.Click += (_, _) => ShowOAuthPanel();

        btn.Paint += (_, e) =>
        {
            var color = hover ? TextSecondary : TextMuted;
            LucideIcons.Draw(e.Graphics, "arrow-left", new Rectangle(0, 3, 16, 16), color);
        };

        btn.Controls.Add(lbl);
        return btn;
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
        Font = Mono(7.5f), // 10px
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
            Font = Mono(7.5f), // 10px
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
            try
            {
                System.Diagnostics.Process.Start(
                    new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
            }
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

        // Sign-in button
        _signInButton.Enabled = !loading;
        _signInLabel.Text = loading ? "signing in..." : "sign in";
        _signInButton.Invalidate();

        // Input fields
        _emailBox.Enabled = !loading;
        _passwordBox.Enabled = !loading;

        // Back button
        _backButton.Enabled = !loading;
        foreach (Control c in _backButton.Controls)
            c.Cursor = loading ? Cursors.Default : Cursors.Hand;
        _backButton.Cursor = loading ? Cursors.Default : Cursors.Hand;

        // Disable ALL OAuth buttons
        foreach (Control c in _oauthPanel.Controls)
        {
            c.Enabled = !loading;
            c.Cursor = loading ? Cursors.Default : Cursors.Hand;
            // Also update child label cursors
            foreach (Control child in c.Controls)
                child.Cursor = loading ? Cursors.Default : Cursors.Hand;
            c.Invalidate();
        }
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
