using System;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using Xunit;
using System.Text.Json;

namespace InputBridge.Windows.Tests;

public class BatteryWireTests
{
    private static string FixturePath()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "shared", "fixtures", "battery-readings.json");
            if (File.Exists(candidate)) return candidate;
            dir = dir.Parent;
        }
        throw new FileNotFoundException("shared/fixtures/battery-readings.json not found above " + AppContext.BaseDirectory);
    }

    [Fact]
    public void Wire_RoundTripsFixture()
    {
        var json = File.ReadAllText(FixturePath());

        var readings = BatteryWire.Deserialize(json);

        var reading = Assert.Single(readings);
        Assert.Equal("logitech-keyboard", reading.DeviceId);
        Assert.Equal("G915 TKL", reading.Name);
        Assert.Equal(DeviceKind.Keyboard, reading.Kind);
        Assert.Equal(new DateTimeOffset(2026, 11, 19, 10, 0, 0, TimeSpan.Zero), reading.ReadAt);
        Assert.Equal([new BatteryComponent(ComponentRole.Main, 82, false)], reading.Components);

        using var expected = JsonDocument.Parse(json);
        using var actual = JsonDocument.Parse(BatteryWire.Serialize(readings));
        AssertJsonEqual(expected.RootElement, actual.RootElement);
    }

    [Fact]
    public void Deserialize_RejectsMalformedJson()
    {
        Assert.ThrowsAny<JsonException>(() => BatteryWire.Deserialize("{ not json"));
    }

    [Fact]
    public void Deserialize_RejectsIncompleteReading()
    {
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize("{\"readings\":[{\"name\":\"x\"}]}"));
    }

    private static void AssertJsonEqual(JsonElement expected, JsonElement actual)
    {
        Assert.Equal(expected.ValueKind, actual.ValueKind);
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                var expectedProps = expected.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal).ToList();
                var actualProps = actual.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal).ToList();
                Assert.Equal(expectedProps.Select(p => p.Name), actualProps.Select(p => p.Name));
                for (var i = 0; i < expectedProps.Count; i++) AssertJsonEqual(expectedProps[i].Value, actualProps[i].Value);
                break;
            case JsonValueKind.Array:
                var e = expected.EnumerateArray().ToList();
                var a = actual.EnumerateArray().ToList();
                Assert.Equal(e.Count, a.Count);
                for (var i = 0; i < e.Count; i++) AssertJsonEqual(e[i], a[i]);
                break;
            case JsonValueKind.String:
                // Timestamps may differ only in formatting (Z vs +00:00, fractional seconds).
                if (expected.TryGetDateTimeOffset(out var et))
                    Assert.Equal(et, actual.GetDateTimeOffset());
                else
                    Assert.Equal(expected.GetString(), actual.GetString());
                break;
            default:
                Assert.Equal(expected.GetRawText(), actual.GetRawText());
                break;
        }
    }
}
