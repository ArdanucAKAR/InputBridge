using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace InputBridge.Windows;

public enum IconTone { Normal, Low, Charging }

/// <summary>What a device's tray icon shows: its number, colour tone, tooltip and stable shell GUID.</summary>
public static class BatteryIconVisual
{
    public const int LowPercent = 15;

    /// <summary>NOTIFYICONDATA.szTip holds 128 characters including the terminating null.</summary>
    public const int MaxTooltipLength = 127;

    public static string Label(int percent) => Math.Clamp(percent, 0, 100).ToString(CultureInfo.InvariantCulture);

    /// <summary>The component the icon stands for: the device itself, or the first component when it has no main one.</summary>
    public static BatteryComponent Primary(BatteryReading reading) =>
        reading.Components.FirstOrDefault(c => c.Role == ComponentRole.Main) ?? reading.Components[0];

    public static IconTone Tone(BatteryReading reading)
    {
        var component = Primary(reading);
        if (component.Percent <= LowPercent && !component.Charging) return IconTone.Low;
        return component.Charging ? IconTone.Charging : IconTone.Normal;
    }

    public static string Tooltip(BatteryReading reading)
    {
        var component = Primary(reading);
        var note = component.Charging ? " (charging)" : "";
        var suffix = $" — {Label(component.Percent)}%{note}";
        var name = DisplayName(reading.Name);
        var room = MaxTooltipLength - suffix.Length;
        if (name.Length > room)
        {
            var cut = room - 1;
            if (cut > 0 && char.IsHighSurrogate(name[cut - 1])) cut--;
            name = name[..cut] + "…";
        }
        return name + suffix;
    }

    private static readonly string[] NameTails = [" LIGHTSPEED", " Wireless", " Gaming", " Mechanical"];

    /// <summary>
    /// The name shown to the user (tooltip, Battery page), never used for ids or matching: the device name cut before
    /// its first marketing word, e.g. "G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard" → "G915 TKL".
    /// </summary>
    public static string DisplayName(string name)
    {
        var cut = NameTails
            .Select(tail => name.IndexOf(tail, StringComparison.OrdinalIgnoreCase))
            .Where(index => index > 0)
            .DefaultIfEmpty(name.Length)
            .Min();
        var shortName = name[..cut].TrimEnd();
        return shortName.Length > 0 ? shortName : name;
    }

    /// <summary>
    /// Name-based (version 5) GUID of the exe path and device id. Windows binds a tray icon GUID to one executable
    /// path, so the path is part of the key; the same device keeps the same GUID (and the user's pin) across runs.
    /// </summary>
    public static Guid IconGuid(string exePath, string deviceId)
    {
        var hash = SHA1.HashData(Encoding.UTF8.GetBytes(exePath.ToLowerInvariant() + "|" + deviceId));
        var bytes = hash.AsSpan(0, 16).ToArray();
        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x50);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
        return new Guid(bytes, bigEndian: true);
    }
}
