using System;
using System.Drawing;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using TarsyWindows.Assets;
using TarsyWindows.Services;
using TarsyWindows.UI;

namespace TarsyWindows;

static class Program
{
    private const string MutexName = "TarsyWindows_SingleInstance";
    private const string AppVersion = "1.0.0";

    private static DaemonManager _daemon = null!;
    private static NotifyIcon _trayIcon = null!;
    private static ToolStripMenuItem _statusItem = null!;
    private static LoginForm? _loginForm;

    [STAThread]
    static void Main(string[] args)
    {
        // Single-instance enforcement
        using var mutex = new Mutex(true, MutexName, out bool createdNew);
        if (!createdNew) return;

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);

        _daemon = new DaemonManager();

        // Check for existing session synchronously before entering message loop
        bool hasSession = _daemon.HasSession().GetAwaiter().GetResult();

        if (hasSession)
        {
            // Already authenticated — go straight to tray
            SetupTray();
            StartDaemon();
            Application.Run();
        }
        else
        {
            // Show login form → on success show onboarding → then tray
            ShowLogin(firstLaunch: true);
        }
    }

    // ═══════════════════════════════════════════
    //  LOGIN
    // ═══════════════════════════════════════════

    private static void ShowLogin(bool firstLaunch)
    {
        _loginForm = new LoginForm();

        // GitHub OAuth
        _loginForm.GitHubSignInClicked += async (_, _) =>
        {
            _loginForm.SetLoading(true);
            _loginForm.SetStatus("opening browser...");

            try
            {
                var error = await _daemon.SignInWithGitHub();
                if (error != null)
                {
                    _loginForm.SetError(error);
                    _loginForm.SetLoading(false);
                    return;
                }
                OnLoginSuccess(firstLaunch);
            }
            catch (Exception ex)
            {
                _loginForm.SetError($"error: {ex.Message}");
                _loginForm.SetLoading(false);
            }
        };

        // Email/password
        _loginForm.SignInClicked += async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(_loginForm.Email) || string.IsNullOrEmpty(_loginForm.Password))
            {
                _loginForm.SetError("enter email and password");
                return;
            }

            _loginForm.SetLoading(true);
            _loginForm.SetStatus("connecting...");

            try
            {
                var error = await _daemon.SignIn(_loginForm.Email, _loginForm.Password);
                if (error != null)
                {
                    _loginForm.SetError(error);
                    _loginForm.SetLoading(false);
                    return;
                }
                OnLoginSuccess(firstLaunch);
            }
            catch (Exception ex)
            {
                _loginForm.SetError($"error: {ex.Message}");
                _loginForm.SetLoading(false);
            }
        };

        Application.Run(_loginForm);
    }

    private static void OnLoginSuccess(bool showOnboarding)
    {
        _loginForm!.SetStatus("authenticated — starting tarsy...");
        _loginForm.Hide();

        if (showOnboarding)
        {
            ShowOnboarding();
        }
        else
        {
            SetupTray();
            StartDaemon();
        }
    }

    // ═══════════════════════════════════════════
    //  ONBOARDING
    // ═══════════════════════════════════════════

    private static void ShowOnboarding()
    {
        var form = new OnboardingForm();
        form.OnCompleted += (machineName) =>
        {
            // Onboarding done — set up tray and start daemon
            SetupTray();
            StartDaemon();
        };
        form.FormClosed += (_, _) =>
        {
            // If user closes window early (X button), still proceed
            if (!_daemon.IsRunning)
            {
                SetupTray();
                StartDaemon();
            }
        };
        form.Show();
    }

    // ═══════════════════════════════════════════
    //  TRAY ICON & MENU
    // ═══════════════════════════════════════════

    private static readonly Font MenuFontRegular = new Font("Cascadia Code", 10f, FontStyle.Regular);
    private static readonly Font MenuFontSmall = new Font("Cascadia Code", 9f, FontStyle.Regular);

    private static void SetupTray()
    {
        if (_trayIcon != null) return; // Already set up

        // Build icon from embedded asset or fall back
        Icon? trayIco = null;
        try
        {
            var img = IconLoader.AppIcon;
            if (img != null)
            {
                using var bmp = new Bitmap(img, 32, 32);
                trayIco = Icon.FromHandle(bmp.GetHicon());
            }
        }
        catch { }
        trayIco ??= SystemIcons.Application;

        _trayIcon = new NotifyIcon
        {
            Text = "Tarsy",
            Icon = trayIco,
            Visible = true,
        };

        var menu = new ContextMenuStrip();
        menu.BackColor = ColorTranslator.FromHtml("#141417");
        menu.ForeColor = ColorTranslator.FromHtml("#e4e4e7");
        menu.Renderer = new DarkMenuRenderer();
        menu.ShowImageMargin = false;

        // ── Header ──
        var versionItem = new ToolStripMenuItem($"Tarsy v{AppVersion}")
        {
            Enabled = false,
            Font = MenuFontSmall,
            ForeColor = ColorTranslator.FromHtml("#71717a"),
        };
        menu.Items.Add(versionItem);

        _statusItem = new ToolStripMenuItem("● Starting...")
        {
            Enabled = false,
            Font = MenuFontSmall,
            ForeColor = ColorTranslator.FromHtml("#eab308"),
        };
        menu.Items.Add(_statusItem);

        menu.Items.Add(new ToolStripSeparator());

        // ── Actions ──
        var setupItem = new ToolStripMenuItem("Setup...");
        setupItem.Font = MenuFontRegular;
        setupItem.Click += (_, _) =>
        {
            var form = new OnboardingForm();
            form.Show();
            form.Activate();
        };
        menu.Items.Add(setupItem);

        menu.Items.Add(new ToolStripSeparator());

        // ── Sign Out ──
        var signOutItem = new ToolStripMenuItem("Sign Out");
        signOutItem.Font = MenuFontRegular;
        signOutItem.ForeColor = ColorTranslator.FromHtml("#71717a");
        signOutItem.Click += async (_, _) =>
        {
            _statusItem.Text = "● Signing out...";
            _statusItem.ForeColor = ColorTranslator.FromHtml("#eab308");

            await _daemon.SignOut();

            // Tear down tray
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayIcon = null!;

            // Re-create daemon (old one is stopped/disposed)
            _daemon = new DaemonManager();

            // Show login again (not first launch — skip onboarding)
            ShowLogin(firstLaunch: false);
        };
        menu.Items.Add(signOutItem);

        // ── Quit ──
        var quitItem = new ToolStripMenuItem("Quit Tarsy");
        quitItem.Font = MenuFontRegular;
        quitItem.ForeColor = ColorTranslator.FromHtml("#e5716a");
        quitItem.Click += async (_, _) =>
        {
            await _daemon.Stop();
            _trayIcon.Visible = false;
            Application.Exit();
        };
        menu.Items.Add(quitItem);

        _trayIcon.ContextMenuStrip = menu;
    }

    private static void StartDaemon()
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await _daemon.Start();
                UpdateStatus("● Online", ColorTranslator.FromHtml("#86efac"));
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[Tarsy] Daemon start error: {ex.Message}");
                UpdateStatus("● Error", ColorTranslator.FromHtml("#e5716a"));
            }
        });
    }

    private static void UpdateStatus(string text, Color color)
    {
        if (_trayIcon?.ContextMenuStrip == null) return;
        try
        {
            _trayIcon.ContextMenuStrip.Invoke(() =>
            {
                _statusItem.Text = text;
                _statusItem.ForeColor = color;
                _trayIcon.Text = $"Tarsy — {text.Replace("● ", "")}";
            });
        }
        catch { }
    }

    // ═══════════════════════════════════════════
    //  DARK MENU RENDERER
    // ═══════════════════════════════════════════

    private class DarkMenuRenderer : ToolStripProfessionalRenderer
    {
        private static readonly Color MenuBg = ColorTranslator.FromHtml("#141417");
        private static readonly Color MenuBorder = ColorTranslator.FromHtml("#2a2a30");
        private static readonly Color MenuHover = ColorTranslator.FromHtml("#1e1e22");
        private static readonly Color SepColor = ColorTranslator.FromHtml("#222228");

        public DarkMenuRenderer() : base(new DarkColorTable()) { }

        protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e)
        {
            using var brush = new SolidBrush(MenuBg);
            e.Graphics.FillRectangle(brush, e.AffectedBounds);
        }

        protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e)
        {
            using var pen = new Pen(MenuBorder);
            e.Graphics.DrawRectangle(pen, 0, 0, e.AffectedBounds.Width - 1, e.AffectedBounds.Height - 1);
        }

        protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e)
        {
            if (e.Item.Selected && e.Item.Enabled)
            {
                using var brush = new SolidBrush(MenuHover);
                var rect = new Rectangle(Point.Empty, e.Item.Size);
                e.Graphics.FillRectangle(brush, rect);
            }
        }

        protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e)
        {
            int y = e.Item.Height / 2;
            using var pen = new Pen(SepColor);
            e.Graphics.DrawLine(pen, 8, y, e.Item.Width - 8, y);
        }

        protected override void OnRenderImageMargin(ToolStripRenderEventArgs e)
        {
            // No image margin gutter
        }

        protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
        {
            e.Graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
            base.OnRenderItemText(e);
        }

        private class DarkColorTable : ProfessionalColorTable
        {
            public override Color MenuItemSelected => ColorTranslator.FromHtml("#1e1e22");
            public override Color MenuItemBorder => Color.Transparent;
            public override Color MenuBorder => ColorTranslator.FromHtml("#2a2a30");
            public override Color ToolStripDropDownBackground => ColorTranslator.FromHtml("#141417");
            public override Color ImageMarginGradientBegin => ColorTranslator.FromHtml("#141417");
            public override Color ImageMarginGradientMiddle => ColorTranslator.FromHtml("#141417");
            public override Color ImageMarginGradientEnd => ColorTranslator.FromHtml("#141417");
        }
    }
}
