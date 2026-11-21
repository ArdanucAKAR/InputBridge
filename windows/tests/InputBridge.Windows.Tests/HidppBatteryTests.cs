using InputBridge.Windows;
using Xunit;

namespace InputBridge.Windows.Tests;

public class HidppBatteryTests
{
    [Fact] public void Unified_ReadsSocAndCharging() =>
        Assert.Equal(new BatteryComponent(ComponentRole.Main, 82, true), HidppBattery.ParseUnifiedStatus([0x52, 0x08, 0x01, 0x01], true));
    [Fact] public void Unified_NotCharging() =>
        Assert.Equal(new BatteryComponent(ComponentRole.Main, 15, false), HidppBattery.ParseUnifiedStatus([0x0F, 0x02, 0x00, 0x00], true));
    [Fact] public void Unified_ChargeCompleteIsFullNotCharging() =>
        Assert.Equal(new BatteryComponent(ComponentRole.Main, 100, false), HidppBattery.ParseUnifiedStatus([0x64, 0x08, 0x03, 0x01], true));
    [Theory, InlineData(0x08, 100), InlineData(0x04, 60), InlineData(0x02, 20), InlineData(0x01, 5)]
    public void Unified_LevelFlagsWhenNoSoc(byte flags, int pct) =>
        Assert.Equal(pct, HidppBattery.ParseUnifiedStatus([0x00, flags, 0x00, 0x00], false)!.Percent);
    [Fact] public void Unified_ErrorStatusIsNull() =>
        Assert.Null(HidppBattery.ParseUnifiedStatus([0x52, 0x08, 0x04, 0x00], true));
    [Fact] public void Unified_CapabilitiesSocBit()
    {
        Assert.True(HidppBattery.ParseUnifiedCapabilities([0x0F, 0x02]));
        Assert.False(HidppBattery.ParseUnifiedCapabilities([0x0F, 0x01]));
    }
    [Fact] public void Status_Discharging() =>
        Assert.Equal(new BatteryComponent(ComponentRole.Main, 50, false), HidppBattery.ParseBatteryStatus([0x32, 0x1E, 0x00]));
    [Theory, InlineData(1), InlineData(2), InlineData(4)]
    public void Status_ChargingCodes(byte s) => Assert.True(HidppBattery.ParseBatteryStatus([0x32, 0x1E, s])!.Charging);
    [Fact] public void Status_FullIs100() => Assert.Equal(100, HidppBattery.ParseBatteryStatus([0x5A, 0x00, 0x03])!.Percent);
    [Fact] public void Status_InvalidBatteryIsNull() => Assert.Null(HidppBattery.ParseBatteryStatus([0x32, 0x1E, 0x05]));
    [Fact] public void Voltage_4000mVCharging() =>
        Assert.Equal(new BatteryComponent(ComponentRole.Main, 80, true), HidppBattery.ParseVoltage([0x0F, 0xA0, 0x80]));
    [Fact] public void Voltage_3700mV() =>
        Assert.Equal(new BatteryComponent(ComponentRole.Main, 30, false), HidppBattery.ParseVoltage([0x0E, 0x74, 0x00]));
    [Theory, InlineData(4300, 100), InlineData(4200, 100), InlineData(3725, 35), InlineData(3400, 0), InlineData(3000, 0)]
    public void VoltageCurve(int mv, int pct) => Assert.Equal(pct, HidppBattery.VoltageToPercent(mv));
    [Fact] public void ShortPayloadIsNull() => Assert.Null(HidppBattery.ParseVoltage([0x0F]));
    [Theory, InlineData(0, DeviceKind.Keyboard), InlineData(3, DeviceKind.Mouse), InlineData(4, DeviceKind.Trackpad),
        InlineData(8, DeviceKind.Headset), InlineData(7, DeviceKind.Other)]
    public void KindFromType(byte t, DeviceKind k) => Assert.Equal(k, HidppBattery.KindFromHidppType(t));
}
