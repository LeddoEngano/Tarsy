using System;
using System.Threading;
using System.Windows.Forms;
using TarsyWindows.Services;
using TarsyWindows.UI;

namespace TarsyWindows;

static class Program
{
    private const string MutexName = "TarsyWindows_SingleInstance";

    [STAThread]
    static void Main(string[] args)
    {
        // Single-instance enforcement
        using var mutex = new Mutex(true, MutexName, out bool createdNew);
        if (!createdNew) return;

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);

        var daemon = new DaemonManager();

        // Check for existing session synchronously before entering message loop
        bool hasSession = daemon.HasSession().GetAwaiter().GetResult();

        if (hasSession)
        {
            // Already authenticated — go straight to tray
            RunWithTray(daemon);
        }
        else
        {
            // Show login form first
            RunWithLogin(daemon);
        }
    }

    private static void RunWithLogin(DaemonManager daemon)
    {
        var loginForm = new LoginForm();

        loginForm.SignInClicked += async (_, _) =>
        {
            if (string.IsNullOrWhiteSpace(loginForm.Email) || string.IsNullOrEmpty(loginForm.Password))
            {
                loginForm.SetError("enter email and password");
                return;
            }

            loginForm.SetLoading(true);
            loginForm.SetStatus("connecting...");

            try
            {
                var error = await daemon.SignIn(loginForm.Email, loginForm.Password);
                if (error != null)
                {
                    loginForm.SetError(error);
                    loginForm.SetLoading(false);
                    return;
                }

                loginForm.SetStatus("authenticated — starting tarsy...");
                loginForm.Hide();

                // Switch to tray mode
                RunWithTray(daemon);

                // Close login form and end its message loop
                loginForm.Close();
            }
            catch (Exception ex)
            {
                loginForm.SetError($"error: {ex.Message}");
                loginForm.SetLoading(false);
            }
        };

        // Run the login form as the main message loop
        Application.Run(loginForm);
    }

    private static void RunWithTray(DaemonManager daemon)
    {
        var trayIcon = new NotifyIcon
        {
            Text = "Tarsy",
            Visible = true,
        };

        var contextMenu = new ContextMenuStrip();
        contextMenu.Items.Add("Status: Starting...", null, null!).Enabled = false;
        contextMenu.Items.Add(new ToolStripSeparator());
        contextMenu.Items.Add("Settings", null, (_, _) => daemon.ShowOnboarding());
        contextMenu.Items.Add(new ToolStripSeparator());
        contextMenu.Items.Add("Quit Tarsy", null, (_, _) =>
        {
            daemon.Stop().Wait();
            trayIcon.Visible = false;
            Application.Exit();
        });
        trayIcon.ContextMenuStrip = contextMenu;

        // Start daemon in background
        _ = Task.Run(async () =>
        {
            await daemon.Start();

            contextMenu.Invoke(() =>
            {
                trayIcon.Text = "Tarsy — Running";
                if (contextMenu.Items[0] is ToolStripMenuItem statusItem)
                {
                    statusItem.Text = "Status: Online";
                }
            });
        });
    }
}
