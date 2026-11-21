namespace InputBridge.Windows;

/// <summary>One kind of battery-powered device reader. <see cref="Changed"/> may be raised on any thread.</summary>
public interface IBatterySource : IAsyncDisposable
{
    string Name { get; }

    IReadOnlyList<BatteryReading> Current { get; }

    event Action? Changed;

    Task StartAsync(CancellationToken token);
}
