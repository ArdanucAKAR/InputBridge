using System;
using Xunit;

namespace InputBridge.Windows.Tests;

public class BatteryIconVisualTests
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 19, 10, 0, 0, TimeSpan.Zero);

    private static BatteryReading Reading(int percent, bool charging = false, string name = "G915 TKL") =>
        new("logitech-keyboard", name, DeviceKind.Keyboard,
            [new BatteryComponent(ComponentRole.Main, percent, charging)], T0);

    [Theory]
    [InlineData(82, "82")]
    [InlineData(5, "5")]
    [InlineData(100, "100")]
    [InlineData(0, "0")]
    public void Label_is_the_plain_percentage(int percent, string expected) =>
        Assert.Equal(expected, BatteryIconVisual.Label(percent));

    [Fact]
    public void Tone_is_low_at_15_percent_when_not_charging() =>
        Assert.Equal(IconTone.Low, BatteryIconVisual.Tone(Reading(15)));

    [Fact]
    public void Tone_is_charging_at_15_percent_when_charging() =>
        Assert.Equal(IconTone.Charging, BatteryIconVisual.Tone(Reading(15, charging: true)));

    [Fact]
    public void Tone_is_normal_at_16_percent() =>
        Assert.Equal(IconTone.Normal, BatteryIconVisual.Tone(Reading(16)));

    [Fact]
    public void Tooltip_shows_name_and_percentage() =>
        Assert.Equal("G915 TKL — 82%", BatteryIconVisual.Tooltip(Reading(82)));

    [Fact]
    public void Tooltip_ChargingNote() =>
        Assert.EndsWith(" — 40% (charging)", BatteryIconVisual.Tooltip(Reading(40, charging: true)));

    [Fact]
    public void Tooltip_marks_charging() =>
        Assert.Equal("G915 TKL — 82% (charging)", BatteryIconVisual.Tooltip(Reading(82, charging: true)));

    [Fact]
    public void Tooltip_shortens_a_long_name_and_keeps_the_suffix_whole()
    {
        var tip = BatteryIconVisual.Tooltip(Reading(82, charging: true, name: new string('G', 200)));

        Assert.Equal(127, tip.Length);
        Assert.EndsWith("… — 82% (charging)", tip);
        Assert.StartsWith("GGGG", tip);
    }

    private const string G915HidppName = "G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard";

    [Fact]
    public void Tooltip_uses_the_short_display_name_of_the_keyboard() =>
        Assert.Equal("G915 TKL — 82%", BatteryIconVisual.Tooltip(Reading(82, name: G915HidppName)));

    [Theory]
    [InlineData(G915HidppName, "G915 TKL")]
    [InlineData("PRO X 2", "PRO X 2")]
    [InlineData("MX Master 3S", "MX Master 3S")]
    [InlineData("G502 X LIGHTSPEED", "G502 X")]
    [InlineData("G915 wireless keyboard", "G915")]
    [InlineData("Gaming Mouse", "Gaming Mouse")]
    [InlineData("Wireless Mouse", "Wireless Mouse")]
    public void DisplayName_cuts_at_the_first_marketing_word(string name, string expected) =>
        Assert.Equal(expected, BatteryIconVisual.DisplayName(name));

    private const string Exe = @"C:\Program Files\InputBridge\InputBridge.exe";

    [Fact]
    public void IconGuid_is_stable_for_the_same_inputs() =>
        Assert.Equal(BatteryIconVisual.IconGuid(Exe, "logitech-keyboard"), BatteryIconVisual.IconGuid(Exe, "logitech-keyboard"));

    [Fact]
    public void IconGuid_differs_by_device() =>
        Assert.NotEqual(BatteryIconVisual.IconGuid(Exe, "logitech-keyboard"), BatteryIconVisual.IconGuid(Exe, "logitech:PRO X 2"));

    [Fact]
    public void IconGuid_differs_by_exe_path() =>
        Assert.NotEqual(
            BatteryIconVisual.IconGuid(Exe, "logitech-keyboard"),
            BatteryIconVisual.IconGuid(@"F:\dev\InputBridge\bin\InputBridge.exe", "logitech-keyboard"));

    [Fact]
    public void IconGuid_ignores_exe_path_case() =>
        Assert.Equal(
            BatteryIconVisual.IconGuid(Exe, "logitech-keyboard"),
            BatteryIconVisual.IconGuid(Exe.ToUpperInvariant(), "logitech-keyboard"));

    [Fact]
    public void IconGuid_is_an_rfc4122_version_5_guid()
    {
        var text = BatteryIconVisual.IconGuid(Exe, "logitech-keyboard").ToString();

        Assert.Equal('5', text[14]);
        Assert.Contains(text[19], "89ab");
    }
}
