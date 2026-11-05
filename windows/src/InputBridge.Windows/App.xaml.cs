using System.Windows;
using Forms = System.Windows.Forms;

namespace InputBridge.Windows;

public partial class App : System.Windows.Application
{
    public static AppRuntime Runtime { get; private set; } = null!;
    private Forms.NotifyIcon? _tray;
    private Forms.ToolStripMenuItem? _updateMenuItem;
    private System.Drawing.Icon? _trayIcon;
    private System.Drawing.Icon? _badgedTrayIcon;
    private MainWindow? _window;
    private bool _startHidden;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _startHidden = e.Args.Any(x => string.Equals(x, "--background", StringComparison.OrdinalIgnoreCase));
        Runtime = new AppRuntime();
        await Runtime.StartAsync();

        _window = new MainWindow(Runtime);
        MainWindow = _window;
        if (!_startHidden) _window.Show();

        var menu = new Forms.ContextMenuStrip
        {
            Font = new System.Drawing.Font("Segoe UI", 9.5f),
            ShowImageMargin = false,
            Padding = new Forms.Padding(2, 4, 2, 4),
            Renderer = new Forms.ToolStripProfessionalRenderer(new TrayMenuColors()) { RoundedEdges = false }
        };
        var open = new Forms.ToolStripMenuItem("Open InputBridge", null, (_, _) => ShowMainWindow())
        {
            Font = new System.Drawing.Font("Segoe UI", 9.5f, System.Drawing.FontStyle.Bold)
        };
        menu.Items.Add(open);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Apply Windows profile", null, async (_, _) => await Runtime.ApplyProfileAsync(ProfileMode.Windows));
        menu.Items.Add("Apply Mac profile", null, async (_, _) => await Runtime.ApplyProfileAsync(ProfileMode.Mac));
        menu.Items.Add(new Forms.ToolStripSeparator());
        _updateMenuItem = new Forms.ToolStripMenuItem("Check for updates", null, async (_, _) => await OnUpdateMenuClickAsync());
        menu.Items.Add(_updateMenuItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, async (_, _) => await ExitAsync());

        _trayIcon = AppIcons.LoadTrayIcon();
        _tray = new Forms.NotifyIcon
        {
            Text = "InputBridge",
            Icon = _trayIcon,
            Visible = true,
            ContextMenuStrip = menu
        };
        _tray.DoubleClick += (_, _) => ShowMainWindow();
        _tray.BalloonTipClicked += (_, _) =>
        {
            ShowMainWindow();
            _window?.ShowPage(InputBridge.Windows.MainWindow.UpdatesPage);
        };

        Runtime.Updates.Changed += () => Dispatcher.BeginInvoke(RefreshUpdateMenu);
        Runtime.Updates.UpdateReady += info => Dispatcher.BeginInvoke(() => NotifyUpdateReady(info));
        Runtime.Updates.InstallerLaunched += () => Dispatcher.BeginInvoke(async () => await ExitAsync());
        RefreshUpdateMenu();
    }

    private async Task OnUpdateMenuClickAsync()
    {
        if (Runtime.Updates.State == UpdateState.ReadyToInstall)
        {
            Runtime.Updates.TryInstall();
            return;
        }
        await Runtime.Updates.CheckAsync(userInitiated: true);
        if (Runtime.Updates.State != UpdateState.ReadyToInstall)
        {
            _tray?.ShowBalloonTip(4000, "InputBridge", Runtime.Updates.StatusText, Forms.ToolTipIcon.Info);
        }
    }

    private void RefreshUpdateMenu()
    {
        if (_updateMenuItem is null || _tray is null || _trayIcon is null) return;
        var updates = Runtime.Updates;
        var ready = updates.State == UpdateState.ReadyToInstall;
        if (ready)
        {
            _badgedTrayIcon ??= AppIcons.CreateBadgedIcon(_trayIcon);
            _tray.Icon = _badgedTrayIcon;
            _tray.Text = $"InputBridge — update {updates.Latest?.Version} available";
            _updateMenuItem.Font = new System.Drawing.Font(_updateMenuItem.Font, System.Drawing.FontStyle.Bold);
            _updateMenuItem.ForeColor = System.Drawing.Color.FromArgb(234, 88, 12);
        }
        else
        {
            _tray.Icon = _trayIcon;
            _tray.Text = "InputBridge";
            _updateMenuItem.Font = new System.Drawing.Font(_updateMenuItem.Font, System.Drawing.FontStyle.Regular);
            _updateMenuItem.ForeColor = System.Drawing.SystemColors.ControlText;
        }
        _updateMenuItem.Text = updates.State switch
        {
            UpdateState.ReadyToInstall => $"●  Install update {updates.Latest?.Version} and restart",
            UpdateState.Checking => "Checking for updates…",
            UpdateState.Downloading => "Downloading update…",
            UpdateState.Installing => "Installing update…",
            _ => "Check for updates"
        };
        _updateMenuItem.Enabled = updates.State is not (UpdateState.Checking or UpdateState.Downloading or UpdateState.Installing);
    }

    private void NotifyUpdateReady(UpdateInfo info)
    {
        if (Runtime.Settings.AutoInstallUpdates) return;
        _tray?.ShowBalloonTip(
            10000,
            $"InputBridge {info.Version} is available",
            "Click to review and install. InputBridge restarts after the update.",
            Forms.ToolTipIcon.Info);
    }

    private void ShowMainWindow()
    {
        if (_window is null) return;
        _window.Show();
        _window.WindowState = WindowState.Normal;
        _window.Activate();
    }

    private async Task ExitAsync()
    {
        if (_tray is not null) _tray.Visible = false;
        await Runtime.StopAsync();
        Shutdown();
    }

    protected override async void OnExit(ExitEventArgs e)
    {
        if (_tray is not null) _tray.Visible = false;
        if (Runtime is not null) await Runtime.StopAsync();
        base.OnExit(e);
    }

    private sealed class TrayMenuColors : Forms.ProfessionalColorTable
    {
        private static readonly System.Drawing.Color Hover = System.Drawing.Color.FromArgb(232, 240, 254);
        private static readonly System.Drawing.Color Line = System.Drawing.Color.FromArgb(226, 230, 236);
        public override System.Drawing.Color MenuItemSelected => Hover;
        public override System.Drawing.Color MenuItemSelectedGradientBegin => Hover;
        public override System.Drawing.Color MenuItemSelectedGradientEnd => Hover;
        public override System.Drawing.Color MenuItemBorder => Hover;
        public override System.Drawing.Color MenuBorder => Line;
        public override System.Drawing.Color SeparatorDark => Line;
        public override System.Drawing.Color SeparatorLight => System.Drawing.Color.White;
        public override System.Drawing.Color ToolStripDropDownBackground => System.Drawing.Color.White;
        public override System.Drawing.Color ImageMarginGradientBegin => System.Drawing.Color.White;
        public override System.Drawing.Color ImageMarginGradientMiddle => System.Drawing.Color.White;
        public override System.Drawing.Color ImageMarginGradientEnd => System.Drawing.Color.White;
    }
}
