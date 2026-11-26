namespace InputBridge.Windows;

/// <summary>
/// Aggregates the battery sources of this machine and applies the visibility rule: only devices connected to this
/// machine are shown, and none while the indicators are switched off.
/// </summary>
public sealed class BatteryService : IAsyncDisposable
{
    private readonly IReadOnlyList<IBatterySource> _sources;
    private readonly Func<bool> _enabled;

    public BatteryService(IEnumerable<IBatterySource> sources, Func<bool> enabled)
    {
        _sources = sources.ToList();
        _enabled = enabled;
        foreach (var source in _sources) source.Changed += OnSourceChanged;
    }

    public event Action? Changed;

    public IReadOnlyList<BatteryReading> Visible => _enabled() ? LocalReadings() : [];

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
