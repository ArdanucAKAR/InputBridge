namespace InputBridge.Windows;

/// <summary>Pure parsers for HID++ 2.0 battery feature payloads.</summary>
public static class HidppBattery
{
    public const ushort FeatureUnifiedBattery = 0x1004;
    public const ushort FeatureBatteryStatus = 0x1000;
    public const ushort FeatureBatteryVoltage = 0x1001;

    // Generic 1-cell Li-ion discharge curve (mV descending, percent).
    private static readonly (int Mv, int Pct)[] VoltageCurvePoints =
    [
        (4200, 100), (4100, 90), (4000, 80), (3900, 65), (3800, 50), (3750, 40),
        (3700, 30), (3650, 20), (3600, 10), (3500, 5), (3400, 0),
    ];

    /// <summary>Parses get_status (fn 1) params [soc, levelFlags, chargingStatus, externalPower].</summary>
    public static BatteryComponent? ParseUnifiedStatus(ReadOnlySpan<byte> p, bool stateOfChargeSupported)
    {
        if (p.Length < 3) return null;
        int status = p[2];
        if (status >= 4) return null;
        bool charging = status is 1 or 2;
        int percent;
        if (status == 3)
        {
            percent = 100;
        }
        else if (stateOfChargeSupported)
        {
            percent = Math.Clamp((int)p[0], 0, 100);
        }
        else
        {
            byte flags = p[1];
            percent = (flags & 0x08) != 0 ? 100
                : (flags & 0x04) != 0 ? 60
                : (flags & 0x02) != 0 ? 20
                : (flags & 0x01) != 0 ? 5
                : 0;
        }
        return new BatteryComponent(ComponentRole.Main, percent, charging);
    }

    /// <summary>Returns whether the device reports state of charge (capabilities bit 1).</summary>
    public static bool ParseUnifiedCapabilities(ReadOnlySpan<byte> p) => p.Length >= 2 && (p[1] & 0x02) != 0;

    /// <summary>Parses BATTERY_STATUS params [level, nextLevel, status].</summary>
    public static BatteryComponent? ParseBatteryStatus(ReadOnlySpan<byte> p)
    {
        if (p.Length < 3) return null;
        int status = p[2];
        if (status >= 5) return null;
        bool charging = status is 1 or 2 or 4;
        int percent = status == 3 ? 100 : Math.Clamp((int)p[0], 0, 100);
        return new BatteryComponent(ComponentRole.Main, percent, charging);
    }

    /// <summary>Parses BATTERY_VOLTAGE params [mV hi, mV lo, flags].</summary>
    public static BatteryComponent? ParseVoltage(ReadOnlySpan<byte> p)
    {
        if (p.Length < 3) return null;
        int mv = (p[0] << 8) | p[1];
        bool charging = (p[2] & 0x80) != 0;
        return new BatteryComponent(ComponentRole.Main, VoltageToPercent(mv), charging);
    }

    public static int VoltageToPercent(int millivolts)
    {
        var curve = VoltageCurvePoints;
        if (millivolts >= curve[0].Mv) return curve[0].Pct;
        if (millivolts <= curve[^1].Mv) return curve[^1].Pct;
        for (int i = 1; i < curve.Length; i++)
        {
            var (loMv, loPct) = curve[i];
            if (millivolts >= loMv)
            {
                var (hiMv, hiPct) = curve[i - 1];
                return (int)Math.Round(loPct + (hiPct - loPct) * (millivolts - loMv) / (double)(hiMv - loMv));
            }
        }
        return 0;
    }

    /// <summary>Maps the DEVICE_NAME (0x0005) fn 2 device type to a DeviceKind.</summary>
    public static DeviceKind KindFromHidppType(byte deviceType) => deviceType switch
    {
        0 => DeviceKind.Keyboard,
        3 => DeviceKind.Mouse,
        4 => DeviceKind.Trackpad,
        8 => DeviceKind.Headset,
        _ => DeviceKind.Other,
    };
}
