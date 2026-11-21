namespace InputBridge.Windows;

/// <summary>
/// Aggregates the local battery sources and the keyboard reading the Mac shares, and applies the visibility rules.
/// </summary>
public sealed class BatteryService : IAsyncDisposable
{
    private static readonly TimeSpan RemoteLifetime = TimeSpan.FromMinutes(11);

    private readonly IReadOnlyList<IBatterySource> _sources;
    private readonly Func<bool> _enabled;
    private readonly TimeProvider _clock;
    private readonly object _lock = new();
    private IReadOnlyList<(BatteryReading Reading, DateTimeOffset ReceivedAt)> _remote = [];

    public BatteryService(IEnumerable<IBatterySource> sources, Func<bool> enabled, TimeProvider clock)
    {
        _sources = sources.ToList();
        _enabled = enabled;
        _clock = clock;
        foreach (var source in _sources) source.Changed += OnSourceChanged;
    }

    public event Action? Changed;

    public IReadOnlyList<BatteryReading> Visible
    {
        get
        {
            if (!_enabled()) return [];
            var local = LocalReadings();
            var now = _clock.GetUtcNow();
            IReadOnlyList<(BatteryReading Reading, DateTimeOffset ReceivedAt)> remote;
            lock (_lock) remote = _remote;
            var remoteShown = remote
                .Where(x => now - x.ReceivedAt < RemoteLifetime)
                .Select(x => x.Reading)
                .Where(r => !local.Any(l => l.DeviceId == r.DeviceId));
            return local.Concat(remoteShown).ToList();
        }
    }

    public IReadOnlyList<BatteryReading> LocalShared() =>
        LocalReadings().Where(r => r.DeviceId == BatteryIds.SharedKeyboard).ToList();

    public void SetRemote(IReadOnlyList<BatteryReading> readings)
    {
        var now = _clock.GetUtcNow();
        var kept = readings
            .Where(r => r.DeviceId == BatteryIds.SharedKeyboard)
            .GroupBy(r => r.DeviceId)
            .Select(g => (Reading: g.Last() with { Remote = true }, ReceivedAt: now))
            .ToList();
        lock (_lock) _remote = kept;
        RaiseChanged();
    }

    public async Task StartAsync(CancellationToken token)
    {
        foreach (var source in _sources) await source.StartAsync(token);
    }

    public void Refresh() => RaiseChanged();

    public async ValueTask DisposeAsync()
    {
        foreach (var source in _sources)
        {
            source.Changed -= OnSourceChanged;
            await source.DisposeAsync();
        }
    }

    private List<BatteryReading> LocalReadings() =>
        _sources.SelectMany(s => s.Current)
            .OrderBy(r => r.Kind)
            .ThenBy(r => r.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();

    private void OnSourceChanged() => RaiseChanged();

    // Sources raise Changed without isolating subscribers, so no listener failure may escape or starve the others.
    private void RaiseChanged()
    {
        var handlers = Changed;
        if (handlers is null) return;
        foreach (var handler in handlers.GetInvocationList().Cast<Action>())
        {
            try { handler(); }
            catch { /* a failing listener must not break the battery read loop */ }
        }
    }
}
