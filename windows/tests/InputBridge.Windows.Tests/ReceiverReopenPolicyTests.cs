using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace InputBridge.Windows.Tests;

public class ReceiverReopenPolicyTests
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 21, 9, 0, 0, TimeSpan.Zero);
    private const string Receiver = "receiver-a";

    [Fact]
    public void First_open_of_a_key_runs_the_slot_scan_and_later_opens_do_not()
    {
        var clock = new FakeTimeProvider(T0);
        var policy = new ReceiverReopenPolicy(clock);

        Assert.True(policy.OnOpened(Receiver));
        clock.Advance(TimeSpan.FromHours(1));
        policy.OnClosed(Receiver);
        Assert.False(policy.OnOpened(Receiver));
        Assert.False(policy.OnOpened(Receiver));
    }

    [Fact]
    public void Each_receiver_key_gets_its_own_scan()
    {
        var policy = new ReceiverReopenPolicy(new FakeTimeProvider(T0));

        Assert.True(policy.OnOpened(Receiver));
        Assert.True(policy.OnOpened("receiver-b"));
    }

    [Fact]
    public void An_unknown_key_can_open()
    {
        Assert.True(new ReceiverReopenPolicy(new FakeTimeProvider(T0)).CanOpen(Receiver));
    }

    [Fact]
    public void A_close_within_10_seconds_of_opening_backs_off_one_minute()
    {
        var clock = new FakeTimeProvider(T0);
        var policy = new ReceiverReopenPolicy(clock);
        policy.OnOpened(Receiver);
        clock.Advance(TimeSpan.FromSeconds(9));
        policy.OnClosed(Receiver);

        clock.Advance(TimeSpan.FromSeconds(59));
        Assert.False(policy.CanOpen(Receiver));
        clock.Advance(TimeSpan.FromSeconds(1));
        Assert.True(policy.CanOpen(Receiver));
    }

    [Fact]
    public void Repeated_quick_failures_double_the_wait_up_to_30_minutes()
    {
        var clock = new FakeTimeProvider(T0);
        var policy = new ReceiverReopenPolicy(clock);
        foreach (var minutes in new[] { 1, 2, 4, 8, 16, 30, 30 })
        {
            policy.OnOpened(Receiver);
            policy.OnClosed(Receiver);
            clock.Advance(TimeSpan.FromMinutes(minutes) - TimeSpan.FromSeconds(1));
            Assert.False(policy.CanOpen(Receiver));
            clock.Advance(TimeSpan.FromSeconds(1));
            Assert.True(policy.CanOpen(Receiver));
        }
    }

    [Fact]
    public void A_close_after_10_seconds_reopens_at_once_and_resets_the_backoff()
    {
        var clock = new FakeTimeProvider(T0);
        var policy = new ReceiverReopenPolicy(clock);
        policy.OnOpened(Receiver);
        policy.OnClosed(Receiver);                     // quick failure: 1 minute
        clock.Advance(TimeSpan.FromMinutes(1));
        policy.OnOpened(Receiver);
        policy.OnClosed(Receiver);                     // second quick failure: 2 minutes
        clock.Advance(TimeSpan.FromMinutes(2));

        policy.OnOpened(Receiver);
        clock.Advance(TimeSpan.FromSeconds(10));
        policy.OnClosed(Receiver);                     // ran long enough: e.g. a stale handle after resume
        Assert.True(policy.CanOpen(Receiver));

        policy.OnOpened(Receiver);
        policy.OnClosed(Receiver);                     // next quick failure starts again at 1 minute
        clock.Advance(TimeSpan.FromMinutes(1));
        Assert.True(policy.CanOpen(Receiver));
    }
}
