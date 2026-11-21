namespace InputBridge.Windows;

/// <summary>
/// Decides, per receiver key and app session, whether opening a receiver may run the waking slot scan (only the
/// first open does) and when a receiver whose channels keep closing right after opening may be reopened
/// (1, 2, 4, … minutes, at most 30). Pure state without I/O or locking; the caller serialises access.
/// </summary>
internal sealed class ReceiverReopenPolicy(TimeProvider clock)
{
    /// <summary>Channels that close this soon after opening count as a failed open.</summary>
    public static readonly TimeSpan QuickFailure = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan FirstBackoff = TimeSpan.FromMinutes(1);
    private static readonly TimeSpan MaxBackoff = TimeSpan.FromMinutes(30);

    private readonly Dictionary<string, State> _keys = new();

    /// <summary>False while the key is backing off after quick failures.</summary>
    public bool CanOpen(string key) =>
        !_keys.TryGetValue(key, out var state) || state.RetryAt is not { } retryAt || clock.GetUtcNow() >= retryAt;

    /// <summary>The receiver was opened. Returns true only the first time for this key: the one allowed slot scan.</summary>
    public bool OnOpened(string key)
    {
        var state = StateFor(key);
        state.OpenedAt = clock.GetUtcNow();
        state.RetryAt = null;
        if (state.Scanned) return false;
        state.Scanned = true;
        return true;
    }

    /// <summary>The receiver's channels closed on their own (unplugged, stale handle, read loop died).</summary>
    public void OnClosed(string key)
    {
        var state = StateFor(key);
        var now = clock.GetUtcNow();
        if (state.OpenedAt is { } openedAt && now - openedAt < QuickFailure)
        {
            var wait = FirstBackoff * Math.Pow(2, state.QuickFailures);
            state.RetryAt = now + (wait < MaxBackoff ? wait : MaxBackoff);
            state.QuickFailures = Math.Min(state.QuickFailures + 1, 16);
        }
        else
        {
            state.QuickFailures = 0;
            state.RetryAt = null;
        }
        state.OpenedAt = null;
    }

    private State StateFor(string key)
    {
        if (!_keys.TryGetValue(key, out var state)) _keys[key] = state = new State();
        return state;
    }

    private sealed class State
    {
        public bool Scanned;
        public int QuickFailures;
        public DateTimeOffset? OpenedAt;
        public DateTimeOffset? RetryAt;
    }
}
