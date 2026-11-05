namespace InputBridge.Windows;

public sealed class AppRuntime
{
    private readonly SettingsStore _store = new();
    private readonly DdcMonitorService _ddc = new();
    private readonly CameraCaptureService _camera = new();
    private readonly SemaphoreSlim _profileGate = new(1, 1);
    private ControllerServer? _server;
    private (ProfileMode Profile, DateTime At, List<MonitorActionResult> Results)? _lastApplied;
    private (ProfileMode Target, DateTime At)? _keyboardRequest;
    private static readonly TimeSpan DuplicateWindow = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan KeyboardRequestLifetime = TimeSpan.FromSeconds(15);
    private DiscoveryResponder? _discovery;
    private ProfileMode? _cameraProfile;
    private int _stopped;

    public AppSettings Settings { get; }
    public PairingService PairingService { get; }
    public CameraCaptureService Camera => _camera;
    public UpdateService Updates { get; }
    public string Status { get; private set; } = "Starting…";
    public event Action? PairingsChanged;
    public event Action? StatusChanged;

    public AppRuntime()
    {
        Settings = _store.Load();
        PairingService = new PairingService(Settings, _store);
        PairingService.Changed += () => PairingsChanged?.Invoke();
        Updates = new UpdateService(Settings);
    }

    public async Task StartAsync()
    {
        _server = new ControllerServer(this);
        _discovery = new DiscoveryResponder(Settings);
        await _server.StartAsync();
        await _discovery.StartAsync();
        Updates.Start();
        SetStatus($"Ready. Waiting for paired Macs on HTTP {Settings.HttpPort}.");
    }

    public void SaveUpdateSettings(bool autoCheck, bool autoInstall, bool beta)
    {
        var channelChanged = Settings.ReceiveBetaUpdates != beta;
        Settings.AutoCheckUpdates = autoCheck;
        Settings.AutoInstallUpdates = autoInstall;
        Settings.ReceiveBetaUpdates = beta;
        _store.Save(Settings);
        if (channelChanged) _ = Updates.CheckAsync(userInitiated: true);
    }

    public async Task StopAsync()
    {
        if (System.Threading.Interlocked.Exchange(ref _stopped, 1) != 0) return;

        Updates.Dispose();

        if (_discovery is not null)
        {
            await _discovery.DisposeAsync();
            _discovery = null;
        }

        if (_server is not null)
        {
            await _server.DisposeAsync();
            _server = null;
        }

        await _camera.DisposeAsync();
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

    public async Task<IReadOnlyList<CameraDeviceInfo>> ListCamerasAsync() => await CameraCaptureService.EnumerateAsync();

    public void SaveCameraSettings(bool enabled, string deviceId)
    {
        var changed = Settings.CameraShareEnabled != enabled || Settings.CameraDeviceId != deviceId;
        Settings.CameraShareEnabled = enabled;
        Settings.CameraDeviceId = deviceId;
        _store.Save(Settings);
        // Drop a running stream so it stops (share off) or reopens with the newly selected camera.
        if (changed) _ = _camera.StopAsync();
        SetStatus(enabled ? "Camera share enabled." : "Camera share disabled.");
    }

    public async Task<List<MonitorActionResult>> ApplyProfileAsync(ProfileMode profile, ProfileSource source = ProfileSource.Local)
    {
        await _profileGate.WaitAsync();
        try
        {
            // Switching the keyboard makes the Mac detect the change and request the same profile again.
            if (source == ProfileSource.Remote && _lastApplied is { } last &&
                last.Profile == profile && DateTime.UtcNow - last.At < DuplicateWindow)
            {
                return last.Results;
            }

            SetStatus($"Applying {profile} profile…");
            try
            {
                await ApplyCameraAsync(profile);
            }
            catch (Exception ex)
            {
                SetStatus($"{profile} profile camera error: {ex.Message}");
            }
            var result = await Task.Run(() => _ddc.Apply(Settings.Monitors, profile));
            var keyboard = await ApplyKeyboardAsync(profile, source);
            var summary = result.All(x => x.Ok)
                ? $"{profile} profile applied."
                : $"{profile} profile completed with monitor errors.";
            SetStatus(keyboard is null ? summary : $"{summary} {keyboard}");
            _lastApplied = (profile, DateTime.UtcNow, result);
            return result;
        }
        finally
        {
            _profileGate.Release();
        }
    }

    /// <summary>
    /// Mac profile: move the keyboard from this PC's receiver to Bluetooth.
    /// Windows profile requested here: the keyboard is on the Mac's Bluetooth, so ask the Mac to release it.
    /// Windows profile requested by the Mac: the Mac has already switched the keyboard.
    /// </summary>
    private async Task<string?> ApplyKeyboardAsync(ProfileMode profile, ProfileSource source)
    {
        if (!Settings.KeyboardSwitchEnabled) return null;
        try
        {
            var pattern = KeyboardPattern();
            if (profile == ProfileMode.Mac)
            {
                _keyboardRequest = null;
                var switched = await LogitechKeyboard.SwitchAwayFromReceiverAsync(pattern);
                return switched is null ? null : "Keyboard switched to Bluetooth.";
            }

            if (source == ProfileSource.Remote) return null;
            if (await LogitechKeyboard.FindAsync(pattern) is not null) return null; // already on LIGHTSPEED
            _keyboardRequest = (ProfileMode.Windows, DateTime.UtcNow);
            return "Asked the Mac to switch the keyboard.";
        }
        catch (Exception ex)
        {
            return $"Keyboard: {ex.Message}";
        }
    }

    /// <summary>Returns and clears a pending keyboard request for the Mac (see ApplyKeyboardAsync).</summary>
    public ProfileMode? ClaimKeyboardRequest()
    {
        var request = _keyboardRequest;
        _keyboardRequest = null;
        return request is { } r && DateTime.UtcNow - r.At < KeyboardRequestLifetime ? r.Target : null;
    }

    public async Task<KeyboardHostState?> DetectKeyboardAsync() => await LogitechKeyboard.FindAsync(KeyboardPattern());

    public void SaveKeyboardSettings(bool enabled, string pattern)
    {
        var trimmed = pattern.Trim();
        _ = new System.Text.RegularExpressions.Regex(trimmed); // validate
        Settings.KeyboardSwitchEnabled = enabled;
        Settings.KeyboardNamePattern = trimmed.Length == 0 ? "G915|G913" : trimmed;
        _store.Save(Settings);
        SetStatus(enabled ? "Keyboard switching enabled." : "Keyboard switching disabled.");
    }

    private System.Text.RegularExpressions.Regex KeyboardPattern()
    {
        var pattern = string.IsNullOrWhiteSpace(Settings.KeyboardNamePattern) ? "G915|G913" : Settings.KeyboardNamePattern;
        return new System.Text.RegularExpressions.Regex(pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    }

    /// <summary>
    /// The camera is not opened here: the Mac pulls it through <see cref="OpenCameraStreamAsync"/> only
    /// while an app on the Mac uses InputBridge Camera. Switching to Windows releases it for local apps.
    /// </summary>
    private async Task ApplyCameraAsync(ProfileMode profile)
    {
        _cameraProfile = profile;
        if (profile != ProfileMode.Mac) await _camera.StopAsync();
    }

    /// <summary>
    /// Opens the camera for one Mac stream, or returns null while sharing is off or this PC has the
    /// Windows profile. A null profile (controller restarted since the last switch) is allowed.
    /// </summary>
    public async Task<CameraCaptureService.CameraLease?> OpenCameraStreamAsync()
    {
        if (!Settings.CameraShareEnabled || _cameraProfile == ProfileMode.Windows) return null;
        return await _camera.AcquireAsync(Settings.CameraDeviceId);
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
