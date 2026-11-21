using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using Xunit;
using Microsoft.Extensions.Time.Testing;

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

    private static BatteryService Create(FakeSource source, FakeTimeProvider? clock = null, Func<bool>? enabled = null) =>
        new([source], enabled ?? (() => true), clock ?? new FakeTimeProvider(T0));

    private static BatteryReading SharedKeyboard(int percent) =>
        Reading(BatteryIds.SharedKeyboard, "G915 TKL", DeviceKind.Keyboard, percent);

    [Fact]
    public void Remote_HiddenWhenLocalPresent()
    {
        var service = Create(new FakeSource(SharedKeyboard(70)));

        service.SetRemote([SharedKeyboard(40)]);

        var shown = Assert.Single(service.Visible);
        Assert.Equal(70, shown.Components[0].Percent);
        Assert.False(shown.Remote);
    }

    [Fact]
    public void Remote_ShownWhenNoLocal_AndMarkedRemote()
    {
        var service = Create(new FakeSource());

        service.SetRemote([SharedKeyboard(40)]);

        var shown = Assert.Single(service.Visible);
        Assert.Equal(40, shown.Components[0].Percent);
        Assert.True(shown.Remote);
    }

    [Fact]
    public void Remote_ExpiresAfter11Minutes()
    {
        var clock = new FakeTimeProvider(T0);
        var service = Create(new FakeSource(), clock);
        service.SetRemote([SharedKeyboard(40)]);

        clock.Advance(TimeSpan.FromMinutes(10) + TimeSpan.FromSeconds(59));
        Assert.Single(service.Visible);

        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.Empty(service.Visible);
    }

    [Fact]
    public void Remote_IgnoresNonSharedIds()
    {
        var service = Create(new FakeSource());

        service.SetRemote([Reading("apple:AirPods", "AirPods", DeviceKind.Headset, 50)]);

        Assert.Empty(service.Visible);
    }

    [Fact]
    public void Remote_EmptyListClearsPreviousRemote()
    {
        var service = Create(new FakeSource());
        service.SetRemote([SharedKeyboard(40)]);

        service.SetRemote([]);

        Assert.Empty(service.Visible);
    }

    [Fact]
    public void Disabled_ShowsNothing()
    {
        var service = Create(new FakeSource(SharedKeyboard(70)), enabled: () => false);
        service.SetRemote([SharedKeyboard(40)]);

        Assert.Empty(service.Visible);
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
    public void LocalShared_ReturnsOnlySharedLocalReadings()
    {
        var service = Create(new FakeSource(SharedKeyboard(70), Reading("m", "Mouse", DeviceKind.Mouse, 5)));
        service.SetRemote([SharedKeyboard(40)]);

        var shared = Assert.Single(service.LocalShared());
        Assert.Equal(70, shared.Components[0].Percent);
        Assert.False(shared.Remote);
    }

    [Fact]
    public void Changed_FiresOnSourceChangeSetRemoteAndRefresh_AndSurvivesThrowingListener()
    {
        var source = new FakeSource();
        var service = Create(source);
        var count = 0;
        service.Changed += () => throw new InvalidOperationException("listener failure");
        service.Changed += () => count++;

        source.Raise();
        service.SetRemote([]);
        service.Refresh();

        Assert.Equal(3, count);
    }
}
