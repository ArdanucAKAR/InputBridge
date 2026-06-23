using System.Windows;
using Forms = System.Windows.Forms;

namespace InputBridge.Windows;

public partial class App : System.Windows.Application
{
    public static AppRuntime Runtime { get; private set; } = null!;
    private Forms.NotifyIcon? _tray;
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
        menu.Items.Add("Exit", null, async (_, _) => await ExitAsync());

        _tray = new Forms.NotifyIcon
        {
            Text = "InputBridge",
            Icon = System.Drawing.SystemIcons.Application,
            Visible = true,
            ContextMenuStrip = menu
        };
        _tray.DoubleClick += (_, _) => ShowMainWindow();
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
