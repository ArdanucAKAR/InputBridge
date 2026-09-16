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
        RefreshMonitors();
        RefreshPairings();
        RefreshStatus();
        Loaded += async (_, _) => await RefreshCamerasAsync();
    }

    private void RefreshStatus()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.Invoke(RefreshStatus); return; }
        StatusText.Text = _runtime.Status;
        FooterText.Text = $"Controller ID: {_runtime.Settings.ControllerId} • Discovery UDP: {_runtime.Settings.DiscoveryPort} • HTTP: {_runtime.Settings.HttpPort}";
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

    protected override void OnClosing(CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
        base.OnClosing(e);
    }
}
