using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Windows;

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
        catch (Exception ex) { MessageBox.Show(ex.Message, "InputBridge", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private void RefreshMonitors_Click(object sender, RoutedEventArgs e) => RefreshMonitors();

    private void SaveMonitors_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            _runtime.SaveMonitorRows(_monitors);
            RefreshMonitors();
            MessageBox.Show("Monitor setup saved.", "InputBridge");
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "InputBridge", MessageBoxButton.OK, MessageBoxImage.Error); }
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
