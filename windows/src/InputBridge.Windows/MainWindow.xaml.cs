using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;
using WpfMessageBox = System.Windows.MessageBox;

namespace InputBridge.Windows;

public partial class MainWindow : Window
{
    private readonly AppRuntime _runtime;
    private readonly ObservableCollection<MonitorRow> _monitors = [];
    private readonly ObservableCollection<PendingPairingView> _pairings = [];

    public MainWindow(AppRuntime runtime)
    {
        InitializeComponent();
        _runtime = runtime;
        MonitorGrid.ItemsSource = _monitors;
        PairingGrid.ItemsSource = _pairings;
        _runtime.PairingsChanged += RefreshPairings;
        _runtime.StatusChanged += RefreshStatus;
        _runtime.Updates.Changed += RefreshUpdates;
        AutoCheckUpdates.IsChecked = _runtime.Settings.AutoCheckUpdates;
        AutoInstallUpdates.IsChecked = _runtime.Settings.AutoInstallUpdates;
        RefreshUpdates();
        RefreshMonitors();
        RefreshPairings();
        RefreshStatus();
        Loaded += async (_, _) => await RefreshCamerasAsync();
    }

    private void RefreshStatus()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.Invoke(RefreshStatus); return; }
        StatusText.Text = _runtime.Status;
        FooterText.Text = $"UDP {_runtime.Settings.DiscoveryPort} · HTTP {_runtime.Settings.HttpPort}";
        ControllerIdText.Text = $"Controller ID: {_runtime.Settings.ControllerId}";
    }

    private void RefreshMonitors()
    {
        _monitors.Clear();
        foreach (var item in _runtime.GetMonitorRows()) _monitors.Add(item);
    }

    private void RefreshPairings()
    {
        Dispatcher.Invoke(() =>
        {
            _pairings.Clear();
            foreach (var item in _runtime.PairingService.PendingViews()) _pairings.Add(item);
        });
    }

    private async void ApplyWindows_Click(object sender, RoutedEventArgs e) => await Apply(ProfileMode.Windows);
    private async void ApplyMac_Click(object sender, RoutedEventArgs e) => await Apply(ProfileMode.Mac);

    private async Task Apply(ProfileMode profile)
    {
        try { await _runtime.ApplyProfileAsync(profile); RefreshStatus(); }
        catch (Exception ex) { WpfMessageBox.Show(ex.Message, "InputBridge", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void RefreshMonitors_Click(object sender, RoutedEventArgs e) => RefreshMonitors();

    private async void RefreshCameras_Click(object sender, RoutedEventArgs e) => await RefreshCamerasAsync();

    private async Task RefreshCamerasAsync()
    {
        try
        {
            var cameras = await _runtime.ListCamerasAsync();
            CameraList.ItemsSource = cameras;
            CameraShareEnabled.IsChecked = _runtime.Settings.CameraShareEnabled;
            var selected = _runtime.Settings.CameraDeviceId;
            if (string.IsNullOrWhiteSpace(selected)) selected = CameraCaptureService.PreferredDeviceId(cameras);
            CameraList.SelectedValue = cameras.Any(item => item.Id == selected) ? selected : cameras.FirstOrDefault()?.Id;
        }
        catch (Exception ex)
        {
            WpfMessageBox.Show(ex.Message, "InputBridge", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void SaveCamera_Click(object sender, RoutedEventArgs e)
    {
        var id = CameraList.SelectedValue as string ?? "";
        _runtime.SaveCameraSettings(CameraShareEnabled.IsChecked == true, id);
        RefreshStatus();
        WpfMessageBox.Show("Camera setup saved. Apply the Mac profile to start sharing.", "InputBridge");
    }

    private void SaveMonitors_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            _runtime.SaveMonitorRows(_monitors);
            RefreshMonitors();
            WpfMessageBox.Show("Monitor setup saved.", "InputBridge");
        }
        catch (Exception ex) { WpfMessageBox.Show(ex.Message, "InputBridge", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void ApprovePairing_Click(object sender, RoutedEventArgs e)
    {
        if (PairingGrid.SelectedItem is not PendingPairingView selected) return;
        _runtime.PairingService.Approve(selected.RequestId);
        RefreshPairings();
    }

    private void RejectPairing_Click(object sender, RoutedEventArgs e)
    {
        if (PairingGrid.SelectedItem is not PendingPairingView selected) return;
        _runtime.PairingService.Reject(selected.RequestId);
        RefreshPairings();
    }

    private void RefreshUpdates()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(RefreshUpdates); return; }
        var updates = _runtime.Updates;
        var version = updates.IsDevelopmentBuild ? "development build" : updates.CurrentVersion.ToString(3);
        CurrentVersionText.Text = $"InputBridge {version}";
        SidebarVersionText.Text = $"Version {version}";
        UpdateStatusText.Text = updates.StatusText;
        var busy = updates.State is UpdateState.Checking or UpdateState.Downloading or UpdateState.Installing;
        CheckUpdatesButton.IsEnabled = !busy;
        InstallUpdateButton.IsEnabled = updates.State == UpdateState.ReadyToInstall;
        ReleaseNotesButton.IsEnabled = !string.IsNullOrEmpty(updates.Latest?.HtmlUrl);

        var ready = updates.State == UpdateState.ReadyToInstall;
        UpdateBanner.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        UpdatesNavBadge.Visibility = ready ? Visibility.Visible : Visibility.Collapsed;
        UpdateBannerTitle.Text = $"InputBridge {updates.Latest?.Version.ToString(3)} is ready to install";
        Taskbar.Overlay = ready ? (_overlay ??= AppIcons.CreateTaskbarOverlay()) : null;
        Taskbar.Description = ready ? "InputBridge — update available" : "InputBridge";
    }

    private System.Windows.Media.ImageSource? _overlay;

    public void ShowPage(int index) => NavList.SelectedIndex = index;

    private void UpdateSettings_Click(object sender, RoutedEventArgs e)
    {
        _runtime.SaveUpdateSettings(AutoCheckUpdates.IsChecked == true, AutoInstallUpdates.IsChecked == true);
    }

    private async void CheckUpdates_Click(object sender, RoutedEventArgs e)
    {
        await _runtime.Updates.CheckAsync(userInitiated: true);
    }

    private void InstallUpdate_Click(object sender, RoutedEventArgs e)
    {
        _runtime.Updates.TryInstall();
    }

    private void ReleaseNotes_Click(object sender, RoutedEventArgs e)
    {
        if (_runtime.Updates.Latest?.HtmlUrl is not { Length: > 0 } url) return;
        if (!url.StartsWith("https://github.com/", StringComparison.OrdinalIgnoreCase)) return;
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
        base.OnClosing(e);
    }
}
