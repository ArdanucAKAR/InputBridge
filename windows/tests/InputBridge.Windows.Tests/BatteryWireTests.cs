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

    private static string One(string id = "logitech-keyboard", string name = "G915", string kind = "\"keyboard\"",
        string components = "[{\"role\":\"main\",\"percent\":50,\"charging\":false}]") =>
        "{\"readings\":[{\"deviceId\":\"" + id + "\",\"name\":\"" + name + "\",\"kind\":" + kind +
        ",\"components\":" + components + ",\"readAt\":\"2026-11-19T10:00:00Z\"}]}";

    [Fact]
    public void Deserialize_AcceptsBoundaryValues()
    {
        var json = One(id: new string('a', 128), components: "[{\"role\":\"main\",\"percent\":0,\"charging\":false},{\"role\":\"left\",\"percent\":100,\"charging\":true},{\"role\":\"right\",\"percent\":1,\"charging\":true}]");
        Assert.Equal(3, Assert.Single(BatteryWire.Deserialize(json)).Components.Count);
    }

    [Theory]
    [InlineData("-1")]
    [InlineData("101")]
    [InlineData("9999")]
    public void Deserialize_RejectsPercentOutOfRange(string percent) =>
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize(
            One(components: "[{\"role\":\"main\",\"percent\":" + percent + ",\"charging\":false}]")));

    [Fact]
    public void Deserialize_RejectsEmptyOrTooManyComponents()
    {
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize(One(components: "[]")));
        var c = "{\"role\":\"main\",\"percent\":5,\"charging\":false}";
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize(One(components: "[" + c + "," + c + "," + c + "," + c + "]")));
    }

    [Fact]
    public void Deserialize_RejectsTooManyReadings()
    {
        var item = "{\"deviceId\":\"a\",\"name\":\"n\",\"kind\":\"mouse\",\"components\":[{\"role\":\"main\",\"percent\":5,\"charging\":false}],\"readAt\":\"2026-11-19T10:00:00Z\"}";
        Assert.Equal(8, BatteryWire.Deserialize("{\"readings\":[" + string.Join(",", Enumerable.Repeat(item, 8)) + "]}").Count);
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize("{\"readings\":[" + string.Join(",", Enumerable.Repeat(item, 9)) + "]}"));
    }

    [Fact]
    public void Deserialize_RejectsBadIdOrName()
    {
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize(One(id: "")));
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize(One(name: "")));
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize(One(id: new string('a', 129))));
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize(One(name: new string('n', 129))));
    }

    [Theory]
    [InlineData("1")]
    [InlineData("99")]
    [InlineData("\"bogus\"")]
    public void Deserialize_RejectsIntegerOrUnknownKind(string kind) =>
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize(One(kind: kind)));

    [Fact]
    public void Deserialize_RejectsIntegerRole() =>
        Assert.Throws<JsonException>(() => BatteryWire.Deserialize(
            One(components: "[{\"role\":0,\"percent\":50,\"charging\":false}]")));

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
