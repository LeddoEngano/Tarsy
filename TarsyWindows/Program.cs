using System;
using System.Threading;
using System.Windows.Forms;
using TarsyWindows.Services;

namespace TarsyWindows;

static class Program
{
    private const string MutexName = "TarsyWindows_SingleInstance";

    [STAThread]
    static void Main(string[] args)
    {
        // Single-instance enforcement
        using var mutex = new Mutex(true, MutexName, out bool createdNew);
        if (!createdNew)
        {
            // Another instance is already running
            return;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);

        var daemon = new DaemonManager();

        // System tray icon
        using var trayIcon = new NotifyIcon
        {
            Text = "Tarsy",
            Visible = true,
            // Icon will be loaded from embedded resource in production
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

        // Start daemon
        _ = Task.Run(async () =>
        {
            await daemon.Start();

            // Marshal UI update to STA thread
            contextMenu.Invoke(() =>
            {
                trayIcon.Text = "Tarsy — Running";
                if (contextMenu.Items[0] is ToolStripMenuItem statusItem)
                {
                    statusItem.Text = "Status: Online";
                }
            });
        });

        Application.Run();
    }
}
