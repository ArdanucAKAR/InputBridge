using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using Xunit;

namespace InputBridge.Windows.Tests;

public class BatteryServiceTests
{
    private sealed class FakeSource(params BatteryReading[] readings) : IBatterySource
    {
        public string Name => "fake";
        public IReadOnlyList<BatteryReading> Current { get; set; } = readings;
        public event Action? Changed;
        public Task StartAsync(CancellationToken token) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        public void Raise() => Changed?.Invoke();
    }

    private static readonly DateTimeOffset T0 = new(2026, 11, 19, 10, 0, 0, TimeSpan.Zero);

    private static BatteryReading Reading(string id, string name, DeviceKind kind, int percent) =>
        new(id, name, kind, [new BatteryComponent(ComponentRole.Main, percent, false)], T0);

    private static BatteryService Create(FakeSource source, Func<bool>? enabled = null) =>
        new([source], enabled ?? (() => true));

    private static BatteryReading SharedKeyboard(int percent) =>
        Reading(BatteryIds.SharedKeyboard, "G915 TKL", DeviceKind.Keyboard, percent);

    [Fact]
    public void Visible_IsEmptyWhenDisabled()
    {
        var service = Create(new FakeSource(SharedKeyboard(40)), enabled: () => false);

        Assert.Empty(service.Visible);
    }

    [Fact]
    public void Visible_ReturnsLocalReadingsWhenEnabled()
    {
        var service = Create(new FakeSource(SharedKeyboard(40)));

        Assert.Equal(40, Assert.Single(service.Visible).Components[0].Percent);
    }

    [Fact]
    public void Order_KeyboardMouseHeadset()
    {
        var service = Create(new FakeSource(
            Reading("h", "Headset", DeviceKind.Headset, 1),
            Reading("m2", "Zed Mouse", DeviceKind.Mouse, 2),
            Reading("k", "Keys", DeviceKind.Keyboard, 3),
            Reading("m1", "Alpha Mouse", DeviceKind.Mouse, 4)));

        Assert.Equal(["Keys", "Alpha Mouse", "Zed Mouse", "Headset"], service.Visible.Select(r => r.Name));
    }

    [Fact]
    public void Changed_FiresOnSourceChangeAndRefresh_AndSurvivesThrowingListener()
    {
        var source = new FakeSource();
        var service = Create(source);
        var count = 0;
        service.Changed += () => throw new InvalidOperationException("listener failure");
        service.Changed += () => count++;

        source.Raise();
        service.Refresh();

        Assert.Equal(2, count);
    }
}
