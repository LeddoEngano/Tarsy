using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using TarsyWindows.Assets;
using TarsyWindows.Terminal;

namespace TarsyWindows.UI;

/// <summary>
/// Multi-step onboarding window — mirrors macOS OnboardingWindow.
/// Steps: Machine Name → System Check → AI Agents → Ready.
/// </summary>
public class OnboardingForm : Form
{
    // ── Theme ──
    private static readonly Color BgPrimary = ColorTranslator.FromHtml("#0a0a0a");
    private static readonly Color BgCard = ColorTranslator.FromHtml("#141417");
    private static readonly Color BgInput = ColorTranslator.FromHtml("#18181c");
    private static readonly Color BorderColor = ColorTranslator.FromHtml("#2a2a30");
    private static readonly Color TextPrimary = ColorTranslator.FromHtml("#e4e4e7");
    private static readonly Color TextSecondary = ColorTranslator.FromHtml("#71717a");
    private static readonly Color TextMuted = ColorTranslator.FromHtml("#52525b");
    private static readonly Color AccentWhite = ColorTranslator.FromHtml("#ffffff");
    private static readonly Color SuccessColor = ColorTranslator.FromHtml("#22c55e");
    private static readonly Color WarningColor = ColorTranslator.FromHtml("#eab308");
    private static readonly Color ErrorColor = ColorTranslator.FromHtml("#e5716a");

    private static Font Mono(float size, FontStyle style = FontStyle.Regular)
        => new("Cascadia Code", size, style);

    // ── Layout constants — never rely on runtime ClientSize ──
    private const int FormW = 480;
    private const int FormH = 560;
    private const int DotH = 40;

    // ── State ──
    private enum Step { MachineName, SystemCheck, Agents, Ready }
    private Step _currentStep = Step.MachineName;
    private string _machineName = Environment.MachineName;

    // System check results
    private bool _ffmpegFound;
    private string? _ffmpegPath;
    private bool _portAvailable;

    // Agent results
    private List<AgentDetector.AgentInfo> _agents = new();

    // ── UI ──
    private Panel _stepPanel = null!;
    private Panel _dotIndicator = null!;

    public string MachineName => _machineName;

    /// <summary>
    /// Fired when onboarding completes. The string is the chosen machine display name.
    /// </summary>
    public event Action<string>? OnCompleted;

    public OnboardingForm()
    {
        InitializeForm();
        BuildShell();
        ShowStep(Step.MachineName);
    }

    private void InitializeForm()
    {
        Text = "Tarsy Setup";
        ClientSize = new Size(FormW, FormH + 32); // +32 for custom title bar
        FormBorderStyle = FormBorderStyle.None;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = BgPrimary;
        ForeColor = TextPrimary;
        DoubleBuffered = true;

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

        // Custom title bar replaces native chrome
        Controls.Add(new CustomTitleBar(this, "tarsy setup"));
    }

    private void BuildShell()
    {
        // Dot indicator pinned to bottom
        _dotIndicator = new Panel
        {
            Location = new Point(0, 32 + FormH - DotH),
            Size = new Size(FormW, DotH),
            BackColor = BgPrimary,
        };
        _dotIndicator.Paint += PaintDots;

        // Step panel fills the area between custom title bar and dot indicator
        _stepPanel = new Panel
        {
            Location = new Point(0, 32),
            Size = new Size(FormW, FormH - DotH),
            BackColor = BgPrimary,
        };

        Controls.Add(_stepPanel);
        Controls.Add(_dotIndicator);
    }

    // ═══════════════════════════════════════════
    //  STEP NAVIGATION
    // ═══════════════════════════════════════════

    private void ShowStep(Step step)
    {
        _currentStep = step;
        _stepPanel.Controls.Clear();
        _dotIndicator.Invalidate();

        switch (step)
        {
            case Step.MachineName: BuildMachineNameStep(); break;
            case Step.SystemCheck: BuildSystemCheckStep(); break;
            case Step.Agents: BuildAgentsStep(); break;
            case Step.Ready: BuildReadyStep(); break;
        }
    }

    private void NextStep()
    {
        var next = _currentStep switch
        {
            Step.MachineName => Step.SystemCheck,
            Step.SystemCheck => Step.Agents,
            Step.Agents => Step.Ready,
            _ => Step.Ready,
        };
        ShowStep(next);
    }

    // ═══════════════════════════════════════════
    //  STEP 1: MACHINE NAME
    // ═══════════════════════════════════════════

    private void BuildMachineNameStep()
    {
        int cx = FormW / 2;
        int availH = FormH - DotH;

        // Block height: logo(48) + 20 + title(28) + 6 + subtitle(20) + 28 + input(40) + 20 + button(40) = 250
        int titleH = 28;
        int subtitleH = 20;
        int blockH = 48 + 20 + titleH + 6 + subtitleH + 28 + 40 + 20 + 40;
        int y = (availH - blockH) / 2;

        // Logo
        var logo = new PictureBox
        {
            Size = new Size(48, 48),
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Color.Transparent,
            Image = IconLoader.TarsyLogo,
            Location = new Point(cx - 24, y),
        };
        y += 48 + 20;

        // Title (full-width, centered)
        var title = MakeCenteredLabel("name this machine", 18f, FontStyle.Bold, TextPrimary, titleH);
        title.Location = new Point(0, y);
        y += titleH + 6;

        // Subtitle (full-width, centered)
        var subtitle = MakeCenteredLabel("this name appears in the tarsy ios app", 11f, FontStyle.Regular, TextSecondary, subtitleH);
        subtitle.Location = new Point(0, y);
        y += subtitleH + 28;

        // Input
        int inputW = 320;
        int inputH = 40;
        var inputContainer = MakeInputContainer(inputW, inputH);
        inputContainer.Location = new Point(cx - inputW / 2, y);

        var nameBox = new TextBox
        {
            Font = Mono(12f),
            ForeColor = TextPrimary,
            BackColor = BgInput,
            BorderStyle = BorderStyle.None,
            Size = new Size(inputW - 32, 20),
            Location = new Point(16, (inputH - 20) / 2),
            Text = _machineName,
            TextAlign = HorizontalAlignment.Center,
        };
        inputContainer.Controls.Add(nameBox);
        y += inputH + 20;

        // Continue button
        var continueBtn = MakeButton("continue", cx - inputW / 2, y, inputW, 40);
        OnButtonClick(continueBtn, () =>
        {
            _machineName = string.IsNullOrWhiteSpace(nameBox.Text) ? Environment.MachineName : nameBox.Text.Trim();
            NextStep();
        });

        nameBox.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Enter)
            {
                e.SuppressKeyPress = true;
                _machineName = string.IsNullOrWhiteSpace(nameBox.Text) ? Environment.MachineName : nameBox.Text.Trim();
                NextStep();
            }
        };

        _stepPanel.Controls.AddRange(new Control[] { logo, title, subtitle, inputContainer, continueBtn });
        nameBox.Focus();
        nameBox.SelectAll();
    }

    // ═══════════════════════════════════════════
    //  STEP 2: SYSTEM CHECK
    // ═══════════════════════════════════════════

    private void BuildSystemCheckStep()
    {
        int cx = FormW / 2;
        int availH = FormH - DotH;
        int itemW = 360;
        int itemX = cx - itemW / 2;

        // Block: title(~26) + 8 + subtitle(~16) + 28 + row(60) + 12 + row(60) + 20 + status(~16) + 16 + installBtn(40) + 12 + continueBtn(40) = ~354
        int blockH = 310; // without install button visible
        int y = Math.Max(16, (availH - blockH) / 2 - 10);

        // Title (full-width centered)
        int titleH = 28;
        int subtitleH = 20;
        int statusH = 20;
        var title = MakeCenteredLabel("system check", 18f, FontStyle.Bold, TextPrimary, titleH);
        title.Location = new Point(0, y);
        y += titleH + 6;

        // Subtitle
        var subtitle = MakeCenteredLabel("checking requirements for screen streaming", 11f, FontStyle.Regular, TextSecondary, subtitleH);
        subtitle.Location = new Point(0, y);
        y += subtitleH + 24;

        // Check rows
        var ffmpegRow = MakeCheckRow("ffmpeg", "required for h.264 screen streaming", itemX, y, itemW);
        y += 60 + 12;

        var portRow = MakeCheckRow("port 8642", "lan direct connection", itemX, y, itemW);
        y += 60 + 20;

        // Status label (full-width centered)
        var statusLabel = MakeCenteredLabel("checking...", 11f, FontStyle.Regular, TextSecondary, statusH);
        statusLabel.Location = new Point(0, y);
        int statusY = y;
        y += statusH + 16;

        // Install ffmpeg button (hidden initially)
        var installBtn = MakeButton("install ffmpeg", cx - 160, y, 320, 40, secondary: true);
        installBtn.Visible = false;
        int installBtnY = y;
        y += 40 + 12;

        // Continue button (always shown after check, position adjusted dynamically)
        int continueBtnY = y;
        var continueBtn = MakeButton("continue", cx - 160, continueBtnY, 320, 40);
        continueBtn.Visible = false;

        OnButtonClick(continueBtn, NextStep);
        OnButtonClick(installBtn, () =>
        {
            installBtn.Visible = false;
            // Move continue up since install button is gone
            continueBtn.Location = new Point(continueBtn.Location.X, installBtnY);
            continueBtn.Enabled = false;

            statusLabel.Text = "preparing download...";
            statusLabel.ForeColor = TextSecondary;

            _ = Task.Run(async () =>
            {
                var success = await InstallFfmpeg((progress, message) =>
                {
                    if (IsHandleCreated)
                    {
                        try
                        {
                            BeginInvoke(() =>
                            {
                                statusLabel.Text = message;
                                statusLabel.ForeColor = TextSecondary;
                            });
                        }
                        catch { }
                    }
                });

                if (!IsHandleCreated) return;
                Invoke(() =>
                {
                    if (success)
                    {
                        _ffmpegPath = FindFfmpeg();
                        _ffmpegFound = _ffmpegPath != null;
                    }

                    if (_ffmpegFound)
                    {
                        UpdateCheckRow(ffmpegRow, true, "installed successfully");
                        statusLabel.Text = "all checks passed";
                        statusLabel.ForeColor = SuccessColor;
                    }
                    else
                    {
                        UpdateCheckRow(ffmpegRow, false, "install failed");
                        statusLabel.Text = "could not download ffmpeg — check internet connection";
                        statusLabel.ForeColor = WarningColor;
                        installBtn.Visible = true;
                        continueBtn.Location = new Point(continueBtn.Location.X, continueBtnY);
                    }
                    continueBtn.Enabled = true;
                    continueBtn.Invalidate();
                });
            });
        });

        _stepPanel.Controls.AddRange(new Control[]
        {
            title, subtitle, ffmpegRow.panel, portRow.panel, statusLabel, installBtn, continueBtn
        });

        // Run checks async
        _ = Task.Run(async () =>
        {
            _ffmpegPath = FindFfmpeg();
            _ffmpegFound = _ffmpegPath != null;
            Invoke(() => UpdateCheckRow(ffmpegRow, _ffmpegFound,
                _ffmpegFound ? "found" : "not installed"));

            _portAvailable = !IsPortInUse(8642);
            Invoke(() => UpdateCheckRow(portRow, _portAvailable,
                _portAvailable ? "available" : "port in use by another app"));

            Invoke(() =>
            {
                if (_ffmpegFound)
                {
                    statusLabel.Text = "all checks passed";
                    statusLabel.ForeColor = SuccessColor;
                    // No install button needed — continue at install button position
                    continueBtn.Location = new Point(continueBtn.Location.X, installBtnY);
                }
                else
                {
                    statusLabel.Text = "ffmpeg is required for screen streaming";
                    statusLabel.ForeColor = WarningColor;
                    installBtn.Visible = true;
                    // continue stays below install button
                }

                CenterLabelAt(statusLabel, cx, statusY);
                continueBtn.Visible = true;
            });
        });
    }

    // ═══════════════════════════════════════════
    //  STEP 3: AI AGENTS
    // ═══════════════════════════════════════════

    private void BuildAgentsStep()
    {
        int cx = FormW / 2;
        int availH = FormH - DotH;
        int listW = 360;

        // Block: title(~26) + 8 + subtitle(~16) + 24 + list(200) + 16 + status(~16) + 16 + buttons(40) = ~362
        int blockH = 362;
        int y = Math.Max(16, (availH - blockH) / 2 - 8);

        int titleH = 28;
        int subtitleH = 20;
        int scanH = 20;
        var title = MakeCenteredLabel("ai agents", 18f, FontStyle.Bold, TextPrimary, titleH);
        title.Location = new Point(0, y);
        y += titleH + 6;

        var subtitle = MakeCenteredLabel("coding agents detected on this machine", 11f, FontStyle.Regular, TextSecondary, subtitleH);
        subtitle.Location = new Point(0, y);
        y += subtitleH + 24;

        // Agent list container (scrollable)
        var listPanel = new Panel
        {
            Location = new Point(cx - listW / 2, y),
            Size = new Size(listW, 200),
            BackColor = BgPrimary,
            AutoScroll = true,
        };
        y += 200 + 16;

        // Scanning status label (full-width centered)
        var scanLabel = MakeCenteredLabel("scanning...", 11f, FontStyle.Regular, TextSecondary, scanH);
        int scanY = y;
        scanLabel.Location = new Point(0, scanY);
        y += scanH + 16;

        // Buttons row — side by side
        int btnW = 160;
        int gap = 16;
        int totalBtnW = btnW * 2 + gap;
        int btnX = cx - totalBtnW / 2;
        var rescanBtn = MakeButton("re-scan", btnX, y, btnW, 40, secondary: true);
        var continueBtn = MakeButton("continue", btnX + btnW + gap, y, btnW, 40);

        OnButtonClick(continueBtn, NextStep);
        OnButtonClick(rescanBtn, () =>
        {
            listPanel.Controls.Clear();
            scanLabel.Text = "scanning...";
            scanLabel.ForeColor = TextSecondary;
            CenterLabelAt(scanLabel, cx, scanY);
            _ = ScanAgents(listPanel, scanLabel, cx, scanY);
        });

        _stepPanel.Controls.AddRange(new Control[] { title, subtitle, listPanel, scanLabel, rescanBtn, continueBtn });

        _ = ScanAgents(listPanel, scanLabel, cx, scanY);
    }

    private async Task ScanAgents(Panel listPanel, Label scanLabel, int cx, int scanY)
    {
        _agents = await AgentDetector.DetectAll(forceRefresh: true);

        Invoke(() =>
        {
            listPanel.Controls.Clear();
            int ay = 0;

            if (_agents.Count == 0)
            {
                scanLabel.Text = "no ai agents found";
                scanLabel.ForeColor = WarningColor;
                CenterLabelAt(scanLabel, cx, scanY);

                var helpLabel = MakeLabel("install claude code, gemini cli, or codex", 10f, FontStyle.Regular, TextMuted);
                helpLabel.Location = new Point(0, 4);
                helpLabel.Size = new Size(listPanel.Width, 20);
                helpLabel.TextAlign = ContentAlignment.MiddleCenter;
                listPanel.Controls.Add(helpLabel);
                return;
            }

            scanLabel.Text = $"{_agents.Count} agent(s) detected";
            scanLabel.ForeColor = SuccessColor;
            CenterLabelAt(scanLabel, cx, scanY);

            foreach (var agent in _agents)
            {
                var row = MakeAgentRow(agent, ay, listPanel.Width);
                listPanel.Controls.Add(row);
                ay += 56; // 52px row + 4px gap
            }
        });
    }

    // ═══════════════════════════════════════════
    //  STEP 4: READY
    // ═══════════════════════════════════════════

    private void BuildReadyStep()
    {
        int cx = FormW / 2;
        int availH = FormH - DotH;

        // Block: logo(64) + 24 + title(~28) + 8 + subtitle(~16) + 28 + summary(~140) + 28 + button(40) = ~376
        int blockH = 376;
        int y = (availH - blockH) / 2;

        // Logo
        var logo = new PictureBox
        {
            Size = new Size(64, 64),
            SizeMode = PictureBoxSizeMode.Zoom,
            BackColor = Color.Transparent,
            Image = IconLoader.TarsyLogo,
            Location = new Point(cx - 32, y),
        };
        y += 64 + 24;

        int titleH = 32;
        int subtitleH = 20;
        var title = MakeCenteredLabel("tarsy is ready!", 20f, FontStyle.Bold, TextPrimary, titleH);
        title.Location = new Point(0, y);
        y += titleH + 6;

        var subtitle = MakeCenteredLabel("everything is set up and running", 11f, FontStyle.Regular, TextSecondary, subtitleH);
        subtitle.Location = new Point(0, y);
        y += subtitleH + 24;

        // Summary card
        int summaryW = 340;
        int summaryH = 136;
        int summaryX = cx - summaryW / 2;

        var summaryPanel = new Panel
        {
            Location = new Point(summaryX, y),
            Size = new Size(summaryW, summaryH),
            BackColor = Color.Transparent,
        };
        summaryPanel.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, summaryW - 1, summaryH - 1);
            using var bg = new SolidBrush(BgCard);
            using var path = RoundedRect(r, 8);
            e.Graphics.FillPath(bg, path);
            using var border = new Pen(BorderColor);
            e.Graphics.DrawPath(border, path);
        };

        int sy = 16;
        int rowH = 26;

        var nameRow = MakeSummaryRow("machine", _machineName, SuccessColor, summaryW);
        nameRow.Location = new Point(0, sy); sy += rowH;

        var ffRow = MakeSummaryRow("ffmpeg", _ffmpegFound ? "found" : "not found", _ffmpegFound ? SuccessColor : WarningColor, summaryW);
        ffRow.Location = new Point(0, sy); sy += rowH;

        var portRow = MakeSummaryRow("port 8642", _portAvailable ? "available" : "in use", _portAvailable ? SuccessColor : WarningColor, summaryW);
        portRow.Location = new Point(0, sy); sy += rowH;

        var agentRow = MakeSummaryRow("agents", $"{_agents.Count} detected", _agents.Count > 0 ? SuccessColor : WarningColor, summaryW);
        agentRow.Location = new Point(0, sy);

        summaryPanel.Controls.AddRange(new Control[] { nameRow, ffRow, portRow, agentRow });
        y += summaryH + 28;

        // Done button
        var doneBtn = MakeButton("minimize to system tray", cx - 160, y, 320, 40);
        OnButtonClick(doneBtn, () =>
        {
            OnCompleted?.Invoke(_machineName);
            Close();
        });

        _stepPanel.Controls.AddRange(new Control[] { logo, title, subtitle, summaryPanel, doneBtn });
    }

    // ═══════════════════════════════════════════
    //  UI FACTORY METHODS
    // ═══════════════════════════════════════════

    private void PaintDots(object? sender, PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int total = 4;
        int dotSize = 8;
        int gap = 12;
        int totalW = total * dotSize + (total - 1) * gap;
        int startX = (_dotIndicator.Width - totalW) / 2;
        int cy = _dotIndicator.Height / 2;
        int current = (int)_currentStep;

        for (int i = 0; i < total; i++)
        {
            var color = i == current ? AccentWhite : (i < current ? TextSecondary : TextMuted);
            using var brush = new SolidBrush(color);
            g.FillEllipse(brush, startX + i * (dotSize + gap), cy - dotSize / 2, dotSize, dotSize);
        }
    }

    private static Label MakeLabel(string text, float size, FontStyle style, Color color)
    {
        return new Label
        {
            Text = text,
            Font = Mono(size, style),
            ForeColor = color,
            BackColor = Color.Transparent,
            AutoSize = true,
        };
    }

    /// <summary>
    /// Creates a full-width label centered horizontally via TextAlign.MiddleCenter.
    /// More reliable than AutoSize+manual centering since WinForms handles the math.
    /// Returns a Label with explicit Size = (FormW, height).
    /// </summary>
    private static Label MakeCenteredLabel(string text, float size, FontStyle style, Color color, int height)
    {
        return new Label
        {
            Text = text,
            Font = Mono(size, style),
            ForeColor = color,
            BackColor = Color.Transparent,
            AutoSize = false,
            Size = new Size(FormW, height),
            TextAlign = ContentAlignment.MiddleCenter,
        };
    }

    /// <summary>
    /// Center an AutoSize label horizontally at cx, keeping its Y at fixedY.
    /// </summary>
    private static void CenterLabelAt(Label lbl, int cx, int fixedY)
    {
        lbl.Location = new Point(cx - lbl.Width / 2, fixedY);
    }

    private static Panel MakeInputContainer(int w, int h)
    {
        var container = new Panel { Size = new Size(w, h), BackColor = Color.Transparent };
        container.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, w - 1, h - 1);
            using var bg = new SolidBrush(BgInput);
            using var path = RoundedRect(r, 8);
            e.Graphics.FillPath(bg, path);
            using var border = new Pen(BorderColor);
            e.Graphics.DrawPath(border, path);
        };
        return container;
    }

    /// <summary>
    /// Creates a styled button panel. Use OnButtonClick to wire handlers —
    /// both panel and label clicks fire the same action.
    /// </summary>
    private Panel MakeButton(string text, int x, int y, int w, int h, bool secondary = false)
    {
        Action? onClick = null;

        var btn = new Panel
        {
            Size = new Size(w, h),
            Location = new Point(x, y),
            BackColor = Color.Transparent,
            Cursor = Cursors.Hand,
        };
        var lbl = new Label
        {
            Text = text,
            Font = Mono(13f, FontStyle.Bold),
            Dock = DockStyle.Fill,
            TextAlign = ContentAlignment.MiddleCenter,
            ForeColor = secondary ? TextPrimary : BgPrimary,
            BackColor = Color.Transparent,
            Cursor = Cursors.Hand,
        };

        bool hover = false;
        btn.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, w - 1, h - 1);
            if (secondary)
            {
                using var bg = new SolidBrush(BgCard);
                using var path = RoundedRect(r, 8);
                e.Graphics.FillPath(bg, path);
                int alpha = hover ? 128 : 50;
                using var border = new Pen(Color.FromArgb(alpha, 255, 255, 255));
                e.Graphics.DrawPath(border, path);
            }
            else
            {
                using var bg = new SolidBrush(hover ? Color.FromArgb(220, 220, 220) : AccentWhite);
                using var path = RoundedRect(r, 8);
                e.Graphics.FillPath(bg, path);
            }
        };

        void SetHover(bool h2) { hover = h2; btn.Invalidate(); }
        btn.MouseEnter += (_, _) => SetHover(true);
        btn.MouseLeave += (_, _) => SetHover(false);
        lbl.MouseEnter += (_, _) => SetHover(true);
        lbl.MouseLeave += (_, _) => SetHover(false);

        // Both panel and label fire the same delegate
        btn.Click += (_, _) => onClick?.Invoke();
        lbl.Click += (_, _) => onClick?.Invoke();

        // Tag stores an action-wiring delegate for OnButtonClick
        btn.Tag = (Action<Action>)(a => onClick += a);

        btn.Controls.Add(lbl);
        return btn;
    }

    /// <summary>
    /// Wire a click handler on a button panel created by MakeButton.
    /// Handles clicks on both the panel and the label covering it.
    /// </summary>
    private static void OnButtonClick(Panel btn, Action handler)
    {
        ((Action<Action>)btn.Tag!)(handler);
    }

    private (Panel panel, Label statusLabel, Label detailLabel) MakeCheckRow(
        string name, string detail, int x, int y, int w)
    {
        int h = 60;
        var panel = new Panel { Location = new Point(x, y), Size = new Size(w, h), BackColor = Color.Transparent };
        panel.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            var r = new Rectangle(0, 0, w - 1, h - 1);
            using var bg = new SolidBrush(BgCard);
            using var path = RoundedRect(r, 8);
            e.Graphics.FillPath(bg, path);
            using var border = new Pen(BorderColor);
            e.Graphics.DrawPath(border, path);
        };

        // Status icon — painted circle instead of emoji
        var iconPanel = new Panel
        {
            Location = new Point(16, h / 2 - 10),
            Size = new Size(20, 20),
            BackColor = Color.Transparent,
            Tag = "icon",
        };
        Color iconColor = TextMuted;
        iconPanel.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var brush = new SolidBrush(iconColor);
            // Draw an outlined circle (pending state)
            using var pen = new Pen(iconColor, 1.5f);
            e.Graphics.DrawEllipse(pen, 3, 3, 13, 13);
        };

        var nameLabel = new Label
        {
            Text = name,
            Font = Mono(12f, FontStyle.Bold),
            ForeColor = TextPrimary,
            Location = new Point(44, 12),
            AutoSize = true,
            BackColor = Color.Transparent,
        };

        var detailLabel = new Label
        {
            Text = detail,
            Font = Mono(10f),
            ForeColor = TextSecondary,
            Location = new Point(44, 34),
            Size = new Size(w - 60, 18),
            BackColor = Color.Transparent,
        };

        panel.Controls.AddRange(new Control[] { iconPanel, nameLabel, detailLabel });
        return (panel, nameLabel, detailLabel);
    }

    private static void UpdateCheckRow((Panel panel, Label statusLabel, Label detailLabel) row, bool success, string detail)
    {
        // Find the icon panel and repaint it as filled circle
        var iconPanel = row.panel.Controls.OfType<Panel>().FirstOrDefault(p => p.Tag as string == "icon");
        if (iconPanel != null)
        {
            Color color = success ? SuccessColor : WarningColor;
            // Replace paint handler
            iconPanel.Paint += (_, e) => { }; // no-op, we'll redraw below
            // Clear and re-wire
            var freshPanel = new Panel
            {
                Location = iconPanel.Location,
                Size = iconPanel.Size,
                BackColor = Color.Transparent,
                Tag = "icon",
            };
            Color c = color;
            freshPanel.Paint += (_, e) =>
            {
                e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using var brush = new SolidBrush(c);
                if (success)
                {
                    // Filled circle for success
                    e.Graphics.FillEllipse(brush, 3, 3, 13, 13);
                }
                else
                {
                    // Triangle for warning
                    var pts = new[] { new Point(10, 2), new Point(18, 16), new Point(2, 16) };
                    e.Graphics.FillPolygon(brush, pts);
                }
            };
            row.panel.Controls.Remove(iconPanel);
            row.panel.Controls.Add(freshPanel);
            iconPanel.Dispose();
        }

        row.detailLabel.Text = detail;
        row.detailLabel.ForeColor = success ? SuccessColor : WarningColor;
    }

    private Panel MakeAgentRow(AgentDetector.AgentInfo agent, int y, int w)
    {
        int h = 52;
        var panel = new Panel { Location = new Point(0, y), Size = new Size(w, h), BackColor = Color.Transparent };
        panel.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, w - 1, h - 1);
            using var bg = new SolidBrush(BgCard);
            using var path = RoundedRect(r, 8);
            e.Graphics.FillPath(bg, path);
        };

        // Agent icon
        var iconImg = GetAgentIcon(agent.Name);
        if (iconImg != null)
        {
            var pic = new PictureBox
            {
                Image = iconImg,
                Size = new Size(24, 24),
                SizeMode = PictureBoxSizeMode.Zoom,
                Location = new Point(14, (h - 24) / 2),
                BackColor = Color.Transparent,
            };
            panel.Controls.Add(pic);
        }

        var nameLabel = new Label
        {
            Text = FormatAgentName(agent.Name),
            Font = Mono(11f, FontStyle.Bold),
            ForeColor = TextPrimary,
            Location = new Point(48, 8),
            AutoSize = true,
            BackColor = Color.Transparent,
        };

        var versionLabel = new Label
        {
            Text = agent.Version ?? "unknown version",
            Font = Mono(9f),
            ForeColor = TextSecondary,
            Location = new Point(48, 28),
            AutoSize = true,
            BackColor = Color.Transparent,
        };

        // Green dot indicator (painted, not emoji)
        var dotPanel = new Panel
        {
            Location = new Point(w - 32, (h - 10) / 2),
            Size = new Size(10, 10),
            BackColor = Color.Transparent,
        };
        dotPanel.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var brush = new SolidBrush(SuccessColor);
            e.Graphics.FillEllipse(brush, 0, 0, 9, 9);
        };

        panel.Controls.AddRange(new Control[] { nameLabel, versionLabel, dotPanel });
        return panel;
    }

    /// <summary>
    /// Creates a summary row with a label and value, plus a colored dot indicator.
    /// </summary>
    private Panel MakeSummaryRow(string label, string value, Color dotColor, int w)
    {
        int h = 24;
        var row = new Panel
        {
            Size = new Size(w, h),
            BackColor = Color.Transparent,
        };

        // Colored dot
        var dot = new Panel
        {
            Location = new Point(20, (h - 6) / 2),
            Size = new Size(6, 6),
            BackColor = Color.Transparent,
        };
        dot.Paint += (_, e) =>
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            using var brush = new SolidBrush(dotColor);
            e.Graphics.FillEllipse(brush, 0, 0, 5, 5);
        };

        var lbl = new Label
        {
            Text = label,
            Font = Mono(10f),
            ForeColor = TextSecondary,
            Location = new Point(34, 2),
            AutoSize = true,
            BackColor = Color.Transparent,
        };

        var val = new Label
        {
            Text = value,
            Font = Mono(10f),
            ForeColor = TextPrimary,
            Location = new Point(w / 2 + 10, 2),
            AutoSize = true,
            BackColor = Color.Transparent,
        };

        row.Controls.AddRange(new Control[] { dot, lbl, val });
        return row;
    }

    // ═══════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════

    private static Image? GetAgentIcon(string name) => name switch
    {
        "claude_code" => IconLoader.Claude,
        "gemini" => IconLoader.Gemini,
        "codex" => IconLoader.Codex,
        "aider" => IconLoader.Get("aider-logo"),
        _ => null,
    };

    private static string FormatAgentName(string name) => name switch
    {
        "claude_code" => "Claude Code",
        "gemini" => "Gemini CLI",
        "codex" => "Codex CLI",
        "aider" => "Aider",
        _ => name,
    };

    private static readonly string TarsyFfmpegDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Tarsy", "ffmpeg");

    private static readonly string TarsyFfmpegPath = Path.Combine(TarsyFfmpegDir, "ffmpeg.exe");

    private static string? FindFfmpeg()
    {
        // Check our managed install first
        if (File.Exists(TarsyFfmpegPath)) return TarsyFfmpegPath;

        // Check PATH via where.exe
        try
        {
            using var p = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = "where.exe",
                    Arguments = "ffmpeg.exe",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                }
            };
            p.Start();
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(3000);
            var first = output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.Trim();
            if (first != null && File.Exists(first)) return first;
        }
        catch { }

        // Check known locations
        string[] paths =
        {
            @"C:\ffmpeg\bin\ffmpeg.exe",
            @"C:\Program Files\ffmpeg\bin\ffmpeg.exe",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "scoop", "shims", "ffmpeg.exe"),
        };
        return paths.FirstOrDefault(File.Exists);
    }

    /// <summary>
    /// Downloads a portable static ffmpeg build directly (no installer, no UAC).
    /// Source: BtbN/FFmpeg-Builds release on GitHub.
    /// Saves ffmpeg.exe to %LOCALAPPDATA%\Tarsy\ffmpeg\ffmpeg.exe.
    /// Reports progress via the optional callback (0.0 → 1.0).
    /// </summary>
    private static async Task<bool> InstallFfmpeg(Action<float, string>? onProgress = null)
    {
        // Use the BtbN GitHub release "essentials" build (smallest, ~50MB)
        const string url = "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip";

        var tmpZip = Path.Combine(Path.GetTempPath(), $"tarsy-ffmpeg-{Guid.NewGuid():N}.zip");
        var tmpExtract = Path.Combine(Path.GetTempPath(), $"tarsy-ffmpeg-{Guid.NewGuid():N}");

        try
        {
            // 1. Download
            onProgress?.Invoke(0f, "downloading ffmpeg...");

            using var http = new System.Net.Http.HttpClient();
            http.Timeout = TimeSpan.FromMinutes(10);
            http.DefaultRequestHeaders.UserAgent.ParseAdd("Tarsy/1.0");

            using (var response = await http.GetAsync(url, System.Net.Http.HttpCompletionOption.ResponseHeadersRead))
            {
                response.EnsureSuccessStatusCode();
                var totalBytes = response.Content.Headers.ContentLength ?? -1L;

                using var sourceStream = await response.Content.ReadAsStreamAsync();
                using var fs = File.Create(tmpZip);

                var buffer = new byte[81920];
                long readSoFar = 0;
                int read;
                while ((read = await sourceStream.ReadAsync(buffer)) > 0)
                {
                    await fs.WriteAsync(buffer.AsMemory(0, read));
                    readSoFar += read;
                    if (totalBytes > 0)
                    {
                        float pct = (float)readSoFar / totalBytes;
                        onProgress?.Invoke(pct * 0.85f, $"downloading ffmpeg... {(int)(pct * 100)}%");
                    }
                }
            }

            // 2. Extract — find ffmpeg.exe inside the zip (nested in bin/)
            onProgress?.Invoke(0.9f, "extracting...");
            Directory.CreateDirectory(tmpExtract);
            System.IO.Compression.ZipFile.ExtractToDirectory(tmpZip, tmpExtract);

            // 3. Locate ffmpeg.exe
            var ffmpegExe = Directory.EnumerateFiles(tmpExtract, "ffmpeg.exe", SearchOption.AllDirectories).FirstOrDefault();
            if (ffmpegExe == null) return false;

            // 4. Copy to managed location
            onProgress?.Invoke(0.95f, "installing...");
            Directory.CreateDirectory(TarsyFfmpegDir);
            File.Copy(ffmpegExe, TarsyFfmpegPath, overwrite: true);

            onProgress?.Invoke(1f, "installed");
            return File.Exists(TarsyFfmpegPath);
        }
        catch (Exception ex)
        {
            onProgress?.Invoke(0f, $"error: {ex.Message}");
            return false;
        }
        finally
        {
            try { if (File.Exists(tmpZip)) File.Delete(tmpZip); } catch { }
            try { if (Directory.Exists(tmpExtract)) Directory.Delete(tmpExtract, recursive: true); } catch { }
        }
    }

    private static bool IsPortInUse(int port)
    {
        try
        {
            var listeners = IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners();
            return listeners.Any(ep => ep.Port == port);
        }
        catch { return false; }
    }

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
