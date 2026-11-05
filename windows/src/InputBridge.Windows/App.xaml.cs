using System.Windows;
using Forms = System.Windows.Forms;

namespace InputBridge.Windows;

public partial class App : System.Windows.Application
{
    public static AppRuntime Runtime { get; private set; } = null!;
    private Forms.NotifyIcon? _tray;
    private Forms.ToolStripMenuItem? _updateMenuItem;
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

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open", null, (_, _) => ShowMainWindow());
        menu.Items.Add("Apply Windows profile", null, async (_, _) => await Runtime.ApplyProfileAsync(ProfileMode.Windows));
        menu.Items.Add("Apply Mac profile", null, async (_, _) => await Runtime.ApplyProfileAsync(ProfileMode.Mac));
        menu.Items.Add(new Forms.ToolStripSeparator());
        _updateMenuItem = new Forms.ToolStripMenuItem("Check for updates", null, async (_, _) => await OnUpdateMenuClickAsync());
        menu.Items.Add(_updateMenuItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, async (_, _) => await ExitAsync());

        _tray = new Forms.NotifyIcon
        {
            Text = "InputBridge",
            Icon = System.Drawing.SystemIcons.Application,
            Visible = true,
            ContextMenuStrip = menu
        };
        _tray.DoubleClick += (_, _) => ShowMainWindow();
        _tray.BalloonTipClicked += (_, _) => Runtime.Updates.TryInstall();

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
        if (_updateMenuItem is null) return;
        var updates = Runtime.Updates;
        _updateMenuItem.Text = updates.State switch
        {
            UpdateState.ReadyToInstall => $"Install update {updates.Latest?.Version.ToString(3)} and restart",
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
            $"InputBridge {info.Version.ToString(3)} is available",
            "Click here to install the update. InputBridge will restart.",
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
}
