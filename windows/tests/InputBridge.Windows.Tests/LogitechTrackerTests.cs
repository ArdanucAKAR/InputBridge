using System.Text.RegularExpressions;
using InputBridge.Windows;
using Xunit;

namespace InputBridge.Windows.Tests;

public class LogitechTrackerTests
{
    [Fact] public void Connection_Linked() => Assert.Equal(((byte)1, true), HidppReceiverNotifications.ParseConnection([0x10,0x01,0x41,0x04,0x01,0x45,0x40]));
    [Fact] public void Connection_LinkLost() => Assert.Equal(((byte)1, false), HidppReceiverNotifications.ParseConnection([0x10,0x01,0x41,0x04,0x41,0x45,0x40]));
    [Fact] public void Connection_OtherSubIdIsNull() => Assert.Null(HidppReceiverNotifications.ParseConnection([0x10,0x01,0x40,0x04,0x01,0x45,0x40]));
    [Fact] public void EnableWirelessNotifications_PreservesExistingFlags() =>
        Assert.Equal(new byte[]{0x10,0xFF,0x80,0x00,0x10,0x09,0x00}, HidppReceiverNotifications.WriteNotificationFlagsRequest([0x10,0x08,0x00]));
    [Fact] public void ReadNotificationFlags_Request() =>
        Assert.Equal(new byte[]{0x10,0xFF,0x81,0x00,0x00,0x00,0x00}, HidppReceiverNotifications.ReadNotificationFlagsRequest());
    [Fact] public void BatteryEvent_SoftwareIdZero() { Assert.True(HidppReceiverNotifications.IsBatteryEvent([0x11,0x01,0x06,0x00,0x52], 6)); Assert.False(HidppReceiverNotifications.IsBatteryEvent([0x11,0x01,0x06,0x1C,0x52], 6)); }

    [Fact] public void ReceiverKey_PairsShortAndLongCollectionsOfOneReceiver()
    {
        const string shortPath = @"\\?\hid#vid_046d&pid_c545&mi_02&col01#e&5b9f0ec&0&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}";
        const string longPath = @"\\?\hid#vid_046d&pid_c545&mi_02&col02#e&5b9f0ec&0&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}";
        const string otherReceiver = @"\\?\hid#vid_046d&pid_c54d&mi_02&col02#9&2c48e62d&0&0001#{4d1e55b2-f16f-11cf-88cb-001111000030}";
        Assert.Equal(LogitechBatterySource.ReceiverKey(shortPath), LogitechBatterySource.ReceiverKey(longPath));
        Assert.NotEqual(LogitechBatterySource.ReceiverKey(longPath), LogitechBatterySource.ReceiverKey(otherReceiver));
    }

    [Fact] public void Tracker_LinkLostHidesAndLinkEstablishedRequestsRead()
    {
        var t = new LogitechDeviceTracker(); var now = DateTimeOffset.UtcNow; var kb = new Regex("G915");
        Assert.Equal([(byte)1], t.OnLinked(1));
        t.OnDeviceInfo(1, "G915 TKL", DeviceKind.Keyboard, 0x1001, 6, false);
        t.OnBattery(1, new(ComponentRole.Main, 80, false), now);
        Assert.Equal(BatteryIds.SharedKeyboard, Assert.Single(t.Readings(kb)).DeviceId);
        t.OnLinkLost(1);
        Assert.Empty(t.Readings(kb));
        Assert.Equal([(byte)1], t.OnLinked(1));      // fresh read on wake
        Assert.Empty(t.Readings(kb));                 // nothing shown until the new value arrives
    }

    [Fact] public void Tracker_RefreshOnlyOnlineAfter30Min()
    {
        var t = new LogitechDeviceTracker(); var t0 = DateTimeOffset.UtcNow;
        t.OnLinked(1); t.OnDeviceInfo(1, "G502 X", DeviceKind.Mouse, 0x1004, 7, true); t.OnBattery(1, new(ComponentRole.Main, 70, false), t0);
        Assert.Empty(t.DueForRefresh(t0.AddMinutes(29)));
        Assert.Equal([(byte)1], t.DueForRefresh(t0.AddMinutes(30)));
        t.OnLinkLost(1);
        Assert.Empty(t.DueForRefresh(t0.AddHours(2)));
    }

    [Fact] public void Tracker_OtherDeviceUsesLogitechPrefixedId()
    {
        var t = new LogitechDeviceTracker(); var now = DateTimeOffset.UtcNow;
        t.OnLinked(2); t.OnDeviceInfo(2, "G502 X", DeviceKind.Mouse, 0x1004, 7, true); t.OnBattery(2, new(ComponentRole.Main, 70, true), now);
        var reading = Assert.Single(t.Readings(new Regex("G915")));
        Assert.Equal(("logitech:G502 X", "G502 X", DeviceKind.Mouse, now), (reading.DeviceId, reading.Name, reading.Kind, reading.ReadAt));
        Assert.Equal(new BatteryComponent(ComponentRole.Main, 70, true), Assert.Single(reading.Components));
    }

    [Fact] public void Tracker_FailedRefreshWaitsAnother30Min()
    {
        var t = new LogitechDeviceTracker(); var t0 = DateTimeOffset.UtcNow;
        t.OnLinked(1); t.OnDeviceInfo(1, "G915 TKL", DeviceKind.Keyboard, 0x1001, 6, false); t.OnBattery(1, new(ComponentRole.Main, 80, false), t0);
        t.OnReadAttempt(1, t0.AddMinutes(30));          // no answer: value stays, no retry every tick
        Assert.Empty(t.DueForRefresh(t0.AddMinutes(31)));
        Assert.Equal([(byte)1], t.DueForRefresh(t0.AddMinutes(60)));
    }

    [Fact] public void RegisterReply_ReturnsFlagBytes() =>
        Assert.Equal(new byte[]{0x10,0x08,0x00}, HidppReceiverNotifications.ParseNotificationFlagsReply([0x10,0xFF,0x81,0x00,0x10,0x08,0x00]));
    [Fact] public void RegisterReply_OtherRegisterIsNull() =>
        Assert.Null(HidppReceiverNotifications.ParseNotificationFlagsReply([0x10,0xFF,0x81,0x02,0x10,0x08,0x00]));
    [Fact] public void RegisterWriteReply_Recognised()
    {
        Assert.True(HidppReceiverNotifications.IsNotificationFlagsWriteReply([0x10,0xFF,0x80,0x00,0x00,0x00,0x00]));
        Assert.False(HidppReceiverNotifications.IsNotificationFlagsWriteReply([0x10,0xFF,0x81,0x00,0x00,0x00,0x00]));
    }
    [Fact] public void RegisterError_Recognised()
    {
        Assert.True(HidppReceiverNotifications.IsRegisterError([0x10,0xFF,0x8F,0x81,0x00,0x03,0x00], 0x81));
        Assert.False(HidppReceiverNotifications.IsRegisterError([0x10,0xFF,0x8F,0x80,0x00,0x03,0x00], 0x81));
    }
    [Fact] public void WirelessBit_Detected()
    {
        Assert.True(HidppReceiverNotifications.WirelessNotificationsEnabled([0x00,0x01,0x00]));
        Assert.False(HidppReceiverNotifications.WirelessNotificationsEnabled([0x10,0x08,0x00]));
    }
}
