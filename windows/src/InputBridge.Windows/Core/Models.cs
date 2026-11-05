using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace InputBridge.Windows;

public enum ProfileMode { Windows, Mac }

/// <summary>Where a profile request came from: this PC's UI/tray, or the paired Mac over the API.</summary>
public enum ProfileSource { Local, Remote }

public sealed class AppSettings
{
    public Guid ControllerId { get; set; } = Guid.NewGuid();
    public int HttpPort { get; set; } = 41715;
    public int DiscoveryPort { get; set; } = 41716;
    public string DiscoveryMulticastGroup { get; set; } = "239.255.77.77";
    public List<MonitorProfileSetting> Monitors { get; set; } = [];
    public List<TrustedClient> TrustedClients { get; set; } = [];
    public bool CameraShareEnabled { get; set; }
    public string CameraDeviceId { get; set; } = "";
    public bool KeyboardSwitchEnabled { get; set; } = true;
    public string KeyboardNamePattern { get; set; } = "G915|G913";
    public bool AutoCheckUpdates { get; set; } = true;
    public bool AutoInstallUpdates { get; set; }
    /// <summary>Null until the user chooses; then defaults to true only on beta builds.</summary>
    public bool? BetaUpdatesChoice { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public bool ReceiveBetaUpdates
    {
        get => BetaUpdatesChoice ?? UpdateService.IsRunningPrerelease;
        set => BetaUpdatesChoice = value;
    }
}

public sealed class MonitorProfileSetting
{
    public string Key { get; set; } = "";
    public string Description { get; set; } = "";
    public bool Enabled { get; set; }
    public byte WindowsInput { get; set; } = 0x0F;
    public byte MacInput { get; set; } = 0x12;
}

public sealed class TrustedClient
{
    public Guid ClientId { get; set; }
    public string ClientName { get; set; } = "";
    public string TokenHashBase64 { get; set; } = "";
    public DateTimeOffset PairedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class MonitorRow : INotifyPropertyChanged
{
    public required string Key { get; init; }
    public required string Description { get; init; }
    public int? CurrentInput { get; init; }
    public string CurrentInputHex => CurrentInput is int value ? $"0x{value:X2}" : "n/a";
    private bool _enabled;
    private string _windowsInputHex = "0x0F";
    private string _macInputHex = "0x12";

    public bool Enabled { get => _enabled; set { _enabled = value; OnChanged(); } }
    public string WindowsInputHex { get => _windowsInputHex; set { _windowsInputHex = value; OnChanged(); } }
    public string MacInputHex { get => _macInputHex; set { _macInputHex = value; OnChanged(); } }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnChanged([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed record PendingPairingView(Guid RequestId, string ClientName, DateTimeOffset RequestedAt, string Status)
{
    public string RequestedAtLocal => RequestedAt.LocalDateTime.ToString("g");
}

public sealed record MonitorActionResult(string Key, string Description, int? Before, int Requested, bool Ok, string? Error = null);
