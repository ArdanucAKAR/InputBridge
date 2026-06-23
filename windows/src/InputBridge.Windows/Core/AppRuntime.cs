namespace InputBridge.Windows;

public sealed class AppRuntime
{
    private readonly SettingsStore _store = new();
    private readonly DdcMonitorService _ddc = new();
    private readonly SemaphoreSlim _profileGate = new(1, 1);
    private ControllerServer? _server;
    private DiscoveryResponder? _discovery;

    public AppSettings Settings { get; }
    public PairingService PairingService { get; }
    public string Status { get; private set; } = "Starting…";
    public event Action? PairingsChanged;
    public event Action? StatusChanged;

    public AppRuntime()
    {
        Settings = _store.Load();
        PairingService = new PairingService(Settings, _store);
        PairingService.Changed += () => PairingsChanged?.Invoke();
    }

    public async Task StartAsync()
    {
        _server = new ControllerServer(this);
        _discovery = new DiscoveryResponder(Settings);
        await _server.StartAsync();
        await _discovery.StartAsync();
        SetStatus($"Ready. Waiting for paired Macs on HTTP {Settings.HttpPort}.");
    }

    public async Task StopAsync()
    {
        if (_discovery is not null) await _discovery.DisposeAsync();
        if (_server is not null) await _server.DisposeAsync();
        _profileGate.Dispose();
    }

    public List<MonitorRow> GetMonitorRows()
    {
        var saved = Settings.Monitors.ToDictionary(x => x.Key, StringComparer.OrdinalIgnoreCase);
        return _ddc.Enumerate().Select(info =>
        {
            saved.TryGetValue(info.Key, out var existing);
            return new MonitorRow
            {
                Key = info.Key,
                Description = info.Description,
                CurrentInput = info.CurrentInput,
                Enabled = existing?.Enabled ?? false,
                WindowsInputHex = $"0x{(existing?.WindowsInput ?? 0x0F):X2}",
                MacInputHex = $"0x{(existing?.MacInput ?? 0x12):X2}"
            };
        }).ToList();
    }

    public void SaveMonitorRows(IEnumerable<MonitorRow> rows)
    {
        Settings.Monitors = rows.Select(row => new MonitorProfileSetting
        {
            Key = row.Key,
            Description = row.Description,
            Enabled = row.Enabled,
            WindowsInput = ParseVcp(row.WindowsInputHex),
            MacInput = ParseVcp(row.MacInputHex)
        }).ToList();
        _store.Save(Settings);
        SetStatus("Monitor configuration saved.");
    }

    public async Task<List<MonitorActionResult>> ApplyProfileAsync(ProfileMode profile)
    {
        await _profileGate.WaitAsync();
        try
        {
            SetStatus($"Applying {profile} profile…");
            var result = await Task.Run(() => _ddc.Apply(Settings.Monitors, profile));
            SetStatus(result.All(x => x.Ok)
                ? $"{profile} profile applied."
                : $"{profile} profile completed with monitor errors.");
            return result;
        }
        finally
        {
            _profileGate.Release();
        }
    }

    private void SetStatus(string value)
    {
        Status = value;
        StatusChanged?.Invoke();
    }

    private static byte ParseVcp(string raw)
    {
        var text = raw.Trim();
        if (text.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) text = text[2..];
        if (!byte.TryParse(text, System.Globalization.NumberStyles.HexNumber, null, out var value))
            throw new InvalidOperationException($"Invalid VCP input value: {raw}");
        return value;
    }
}
