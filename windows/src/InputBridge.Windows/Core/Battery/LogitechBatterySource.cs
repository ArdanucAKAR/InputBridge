using System.Diagnostics;
using System.Text.RegularExpressions;

namespace InputBridge.Windows;

/// <summary>
/// Batteries of Logitech devices on LIGHTSPEED/Unifying receivers, driven by HID++ notifications so sleeping devices
/// are never woken: one startup slot scan per receiver and app session, then reads only when a device links, on the
/// device's own battery events, and at most every 30 minutes for devices known to be online. Every open (including a
/// reopen after resume) asks the receiver itself which paired devices are linked, which wakes nothing.
/// </summary>
public sealed class LogitechBatterySource : IBatterySource
{
    private const byte SoftwareId = 0x0C;
    private const ushort ShortUsage = 0x0001;
    private const ushort LongUsage = 0x0002;
    private const ushort FeatureDeviceName = 0x0005;
    private static readonly ushort[] BatteryFeatures =
        [HidppBattery.FeatureUnifiedBattery, HidppBattery.FeatureBatteryStatus, HidppBattery.FeatureBatteryVoltage];
    private static readonly TimeSpan TickInterval = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan RegisterTimeout = TimeSpan.FromMilliseconds(400);

    private readonly Func<Regex> _sharedKeyboardPattern;
    private readonly Action<string>? _log;
    private readonly object _lock = new();
    private readonly Dictionary<string, Receiver> _receivers = new();
    private readonly ReceiverReopenPolicy _reopen = new(TimeProvider.System);
    private readonly CancellationTokenSource _cancel = new();
    private CancellationTokenRegistration _stopRegistration;
    private Task? _loop;

    public LogitechBatterySource(Func<Regex> sharedKeyboardPattern, Action<string>? log = null)
    {
        _sharedKeyboardPattern = sharedKeyboardPattern;
        _log = log;
    }

    public string Name => "Logitech receivers";

    public event Action? Changed;

    public IReadOnlyList<BatteryReading> Current
    {
        get
        {
            var pattern = _sharedKeyboardPattern();
            lock (_lock) return _receivers.Values.SelectMany(receiver => receiver.Tracker.Readings(pattern)).ToList();
        }
    }

    /// <summary>Starts listening in the background and returns at once; readings arrive through <see cref="Changed"/>.</summary>
    public Task StartAsync(CancellationToken token)
    {
        _stopRegistration = token.Register(_cancel.Cancel);
        _loop = Task.Run(() => RunAsync(_cancel.Token));
        return Task.CompletedTask;
    }

    public async ValueTask DisposeAsync()
    {
        _cancel.Cancel();
        await _stopRegistration.DisposeAsync();
        if (_loop is not null) await _loop;
        lock (_lock)
        {
            foreach (var receiver in _receivers.Values) receiver.Dispose();
            _receivers.Clear();
        }
        _cancel.Dispose();
    }

    /// <summary>
    /// Identifies the receiver a HID collection path belongs to, so its short (col01) and long (col02) collections pair up:
    /// drops the collection number and the per-collection instance suffix.
    /// </summary>
    internal static string ReceiverKey(string path) =>
        Regex.Replace(path.ToLowerInvariant(), "&col[0-9a-f]+#([^#]*)&[0-9a-f]+#", "#$1#");

    private async Task RunAsync(CancellationToken token)
    {
        try
        {
            await TickAsync(token);
            using var timer = new PeriodicTimer(TickInterval);
            while (await timer.WaitForNextTickAsync(token)) await TickAsync(token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
    }

    private async Task TickAsync(CancellationToken token)
    {
        try
        {
            // Enumerating receivers never talks to the devices behind them.
            await RescanReceiversAsync(token);
            await RefreshDueAsync(token);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !token.IsCancellationRequested)
        {
            Log($"battery tick failed: {ex.Message}");
        }
    }

    private async Task RescanReceiversAsync(CancellationToken token)
    {
        var longPaths = HidppReceivers.FindPaths(LongUsage);
        var shortPaths = HidppReceivers.FindPaths(ShortUsage);
        var present = longPaths.Select(ReceiverKey).ToHashSet();

        var removed = false;
        lock (_lock)
        {
            foreach (var key in _receivers.Keys.Where(key => !present.Contains(key)).ToList())
            {
                Log($"receiver removed: {key}");
                _receivers[key].Dispose();
                _receivers.Remove(key);
                removed = true;
            }
        }
        if (removed) RaiseChanged();

        var added = new List<(Receiver Receiver, bool Scan)>();
        foreach (var longPath in longPaths)
        {
            var key = ReceiverKey(longPath);
            lock (_lock) { if (_receivers.ContainsKey(key) || !_reopen.CanOpen(key)) continue; }
            var shortPath = shortPaths.FirstOrDefault(path => ReceiverKey(path) == key);
            if (shortPath is null) continue;
            var receiver = OpenReceiver(key, shortPath, longPath, token);
            if (receiver is null) continue;
            bool scan;
            lock (_lock)
            {
                _receivers[key] = receiver;
                scan = _reopen.OnOpened(key);
            }
            WatchForRemoval(receiver);
            added.Add((receiver, scan));
        }
        await Task.WhenAll(added.Select(item => InitialiseAsync(item.Receiver, item.Scan, token)));
    }

    private Receiver? OpenReceiver(string key, string shortPath, string longPath, CancellationToken token)
    {
        var shortChannel = HidppChannel.TryOpen(shortPath, SoftwareId);
        if (shortChannel is null) return null;
        var longChannel = HidppChannel.TryOpen(longPath, SoftwareId);
        if (longChannel is null)
        {
            shortChannel.Dispose();
            return null;
        }

        // Subscribe before sending anything: the channel's read loop is already running.
        var receiver = new Receiver(key, shortChannel, longChannel);
        shortChannel.ReportReceived += report => OnShortReport(receiver, report, token);
        longChannel.ReportReceived += report => OnLongReport(receiver, report);
        Log($"receiver opened: {key}");
        return receiver;
    }

    /// <summary>
    /// A channel's read loop ends on its own when the receiver is unplugged (or the handle goes stale, e.g. across
    /// sleep): drop the receiver at once so its devices disappear, and let a later tick reopen it if it is back. A
    /// receiver that keeps closing right after opening is reopened ever more rarely (<see cref="ReceiverReopenPolicy"/>).
    /// </summary>
    private void WatchForRemoval(Receiver receiver) =>
        _ = Task.WhenAny(receiver.Short.Completion, receiver.Long.Completion).ContinueWith(_ =>
        {
            lock (_lock)
            {
                // Already gone when the source disposed it itself (rescan or shutdown).
                if (!_receivers.TryGetValue(receiver.Key, out var current) || !ReferenceEquals(current, receiver)) return;
                _receivers.Remove(receiver.Key);
                _reopen.OnClosed(receiver.Key);
                receiver.Dispose();
            }
            Log($"receiver closed: {receiver.Key}");
            RaiseChanged();
        }, TaskScheduler.Default);

    /// <param name="receiver">The receiver just opened.</param>
    /// <param name="scan">
    /// Run the slot ping scan: only on the first open of this receiver in the app session, as it wakes sleeping devices.
    /// </param>
    /// <param name="token">Stops the source.</param>
    private async Task InitialiseAsync(Receiver receiver, bool scan, CancellationToken token)
    {
        try
        {
            await EnableWirelessNotificationsAsync(receiver, token);

            // The receiver answers from its own link table with a 0x41 notification per paired device (handled in
            // OnShortReport); no radio traffic, so this is safe on every open.
            var reported = await RegisterRequestAsync(receiver, HidppReceiverNotifications.ReportConnectedDevicesRequest(),
                report => HidppReceiverNotifications.IsReportConnectedDevicesReply(report) ? report : null, token);
            Log($"{receiver.Key}: connected-devices report {(reported is null ? "not confirmed" : "requested")}");
            if (!scan) return;

            // The one allowed startup scan, kept as a fallback for receivers that do not answer the register query:
            // it wakes sleeping devices, so it runs once per receiver per app session.
            List<byte> online;
            await HidppGate.Instance.WaitAsync(token);
            try { online = await receiver.Long.FindOnlineDevicesAsync(FeatureDeviceName, token); }
            finally { HidppGate.Instance.Release(); }
            Log($"{receiver.Key}: online slots [{string.Join(", ", online)}]");

            var toRead = new List<byte>();
            lock (_lock)
            {
                // Slots the receiver already reported as linked are read through their notification.
                foreach (var index in online.Where(index => !receiver.Tracker.IsLinked(index)))
                    toRead.AddRange(receiver.Tracker.OnLinked(index));
            }
            foreach (var index in toRead) await ReadDeviceAsync(receiver, index, discover: true, token);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !token.IsCancellationRequested)
        {
            Log($"{receiver.Key}: initialisation failed: {ex.Message}");
        }
    }

    /// <summary>Turns on the receiver's wireless (link) notifications, keeping every flag that is already set.</summary>
    private async Task EnableWirelessNotificationsAsync(Receiver receiver, CancellationToken token)
    {
        var current = await RegisterRequestAsync(receiver, HidppReceiverNotifications.ReadNotificationFlagsRequest(),
            report => HidppReceiverNotifications.ParseNotificationFlagsReply(report), token);
        if (current is null)
        {
            // Never write without knowing the current flags: that could clear what G HUB enabled.
            Log($"{receiver.Key}: notification flags read failed; register left unchanged");
            return;
        }
        Log($"{receiver.Key}: notification flags {Convert.ToHexString(current)}");
        if (HidppReceiverNotifications.WirelessNotificationsEnabled(current)) return;

        var written = await RegisterRequestAsync(receiver, HidppReceiverNotifications.WriteNotificationFlagsRequest(current),
            report => HidppReceiverNotifications.IsNotificationFlagsWriteReply(report) ? report : null, token);
        Log($"{receiver.Key}: wireless notifications {(written is null ? "not confirmed" : "enabled")}");
    }

    /// <summary>
    /// One short-collection register access <c>[0x10, 0xFF, subId, register, …]</c> under the HID++ gate; null on
    /// timeout or HID++ 1.0 error.
    /// </summary>
    private static async Task<byte[]?> RegisterRequestAsync(Receiver receiver, byte[] request,
        Func<byte[], byte[]?> parseReply, CancellationToken token)
    {
        var (subId, register) = (request[2], request[3]);
        var completion = new TaskCompletionSource<byte[]?>(TaskCreationOptions.RunContinuationsAsynchronously);
        await HidppGate.Instance.WaitAsync(token);
        try
        {
            receiver.RegisterReply = report =>
            {
                if (HidppReceiverNotifications.IsRegisterError(report, subId, register)) completion.TrySetResult(null);
                else if (parseReply(report) is { } reply) completion.TrySetResult(reply);
            };
            await receiver.Short.SendRawAsync(request, token);
            return await completion.Task.WaitAsync(RegisterTimeout, token);
        }
        catch (TimeoutException)
        {
            return null;
        }
        finally
        {
            receiver.RegisterReply = null;
            HidppGate.Instance.Release();
        }
    }

    private void OnShortReport(Receiver receiver, byte[] report, CancellationToken token)
    {
        receiver.RegisterReply?.Invoke(report);
        if (HidppReceiverNotifications.ParseConnection(report) is not { } connection || connection.Index is < 1 or > 6) return;

        Log($"{receiver.Key}: slot {connection.Index} {(connection.Linked ? "linked" : "link lost")}");
        IReadOnlyList<byte> toRead = [];
        lock (_lock)
        {
            if (connection.Linked) toRead = receiver.Tracker.OnLinked(connection.Index);
            else receiver.Tracker.OnLinkLost(connection.Index);
        }
        RaiseChanged();
        // The device just announced itself, so it is awake: reading it now wakes nothing.
        foreach (var index in toRead) _ = Task.Run(() => ReadDeviceAsync(receiver, index, discover: true, token), token);
    }

    private void OnLongReport(Receiver receiver, byte[] report)
    {
        if (report.Length < 5 || report[1] is < 1 or > 6) return;
        var index = report[1];
        lock (_lock)
        {
            var info = receiver.Tracker.Info(index);
            if (info is null || !HidppReceiverNotifications.IsBatteryEvent(report, info.BatteryFeatureIndex)) return;
            if (ParseBattery(info, report.AsSpan(4)) is not { } component) return;
            receiver.Tracker.OnBattery(index, component, DateTimeOffset.UtcNow);
        }
        Log($"{receiver.Key}: slot {index} battery event");
        RaiseChanged();
    }

    private async Task RefreshDueAsync(CancellationToken token)
    {
        var now = DateTimeOffset.UtcNow;
        List<(Receiver Receiver, byte Index)> due;
        lock (_lock)
        {
            due = _receivers.Values.SelectMany(receiver => receiver.Tracker.DueForRefresh(now).Select(index => (receiver, index))).ToList();
        }
        foreach (var (receiver, index) in due) await ReadDeviceAsync(receiver, index, discover: false, token);
    }

    private async Task ReadDeviceAsync(Receiver receiver, byte index, bool discover, CancellationToken token)
    {
        try
        {
            LogitechDeviceInfo? info;
            lock (_lock)
            {
                receiver.Tracker.OnReadAttempt(index, DateTimeOffset.UtcNow);
                info = receiver.Tracker.Info(index);
            }
            if (discover || info is null)
            {
                info = await DiscoverAsync(receiver.Long, index, token);
                if (info is null)
                {
                    Log($"{receiver.Key}: slot {index} has no readable battery");
                    return;
                }
                lock (_lock)
                {
                    receiver.Tracker.OnDeviceInfo(index, info.Name, info.Kind, info.BatteryFeature, info.BatteryFeatureIndex, info.SocSupported);
                }
            }

            var function = info.BatteryFeature == HidppBattery.FeatureUnifiedBattery ? (byte)1 : (byte)0;
            var reply = await RequestAsync(receiver.Long, index, info.BatteryFeatureIndex, function, [], token);
            if (reply is null || ParseBattery(info, reply) is not { } component)
            {
                Log($"{receiver.Key}: slot {index} battery read failed");
                return;
            }
            lock (_lock) receiver.Tracker.OnBattery(index, component, DateTimeOffset.UtcNow);
            Log($"{receiver.Key}: slot {index} '{info.Name}' {component.Percent}%{(component.Charging ? " charging" : "")} via 0x{info.BatteryFeature:X4}");
            RaiseChanged();
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !token.IsCancellationRequested)
        {
            Log($"{receiver.Key}: slot {index} read failed: {ex.Message}");
        }
        catch (OperationCanceledException)
        {
        }
    }

    /// <summary>Name and type (DEVICE_NAME 0x0005) and the first battery feature the device supports.</summary>
    private static async Task<LogitechDeviceInfo?> DiscoverAsync(HidppChannel channel, byte index, CancellationToken token)
    {
        HidppDeviceRequest request = (feature, function, parameters) => RequestAsync(channel, index, feature, function, parameters, token);
        var nameFeature = await HidppDeviceQueries.FeatureIndexAsync(request, FeatureDeviceName);
        if (nameFeature is null) return null;
        var name = await HidppDeviceQueries.DeviceNameAsync(request, nameFeature.Value);
        if (string.IsNullOrEmpty(name)) return null;
        var type = await request(nameFeature.Value, 2, []);
        var kind = type is { Length: > 0 } ? HidppBattery.KindFromHidppType(type[0]) : DeviceKind.Other;

        foreach (var feature in BatteryFeatures)
        {
            var featureIndex = await HidppDeviceQueries.FeatureIndexAsync(request, feature);
            if (featureIndex is null) continue;
            var soc = false;
            if (feature == HidppBattery.FeatureUnifiedBattery)
            {
                var capabilities = await request(featureIndex.Value, 0, []);
                soc = capabilities is not null && HidppBattery.ParseUnifiedCapabilities(capabilities);
            }
            return new LogitechDeviceInfo(name, kind, feature, featureIndex.Value, soc);
        }
        return null;
    }

    private static BatteryComponent? ParseBattery(LogitechDeviceInfo info, ReadOnlySpan<byte> parameters) => info.BatteryFeature switch
    {
        HidppBattery.FeatureUnifiedBattery => HidppBattery.ParseUnifiedStatus(parameters, info.SocSupported),
        HidppBattery.FeatureBatteryStatus => HidppBattery.ParseBatteryStatus(parameters),
        HidppBattery.FeatureBatteryVoltage => HidppBattery.ParseVoltage(parameters),
        _ => null,
    };

    /// <summary>One HID++ request under the shared gate, so a profile switch waits for at most this one request.</summary>
    private static async Task<byte[]?> RequestAsync(HidppChannel channel, byte index, byte feature, byte function, byte[] parameters, CancellationToken token)
    {
        await HidppGate.Instance.WaitAsync(token);
        try { return await channel.RequestAsync(index, feature, function, parameters, token); }
        finally { HidppGate.Instance.Release(); }
    }

    private void RaiseChanged() => Changed?.Invoke();

    private void Log(string message)
    {
        Debug.WriteLine($"[battery] {message}");
        _log?.Invoke(message);
    }

    private sealed class Receiver(string key, HidppChannel shortChannel, HidppChannel longChannel) : IDisposable
    {
        public string Key { get; } = key;
        public HidppChannel Short { get; } = shortChannel;
        public HidppChannel Long { get; } = longChannel;
        public LogitechDeviceTracker Tracker { get; } = new();

        /// <summary>Waiter for the register reply in flight (at most one, under the HID++ gate).</summary>
        public volatile Action<byte[]>? RegisterReply;

        public void Dispose()
        {
            Short.Dispose();
            Long.Dispose();
        }
    }
}
