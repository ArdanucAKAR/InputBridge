using System.Text.Json;
using System.Text.Json.Serialization;

namespace InputBridge.Windows;

/// <summary>JSON wire format of battery readings, shared with the Mac app (see shared/fixtures/battery-readings.json).</summary>
public static class BatteryWire
{
    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private sealed record ComponentDto(ComponentRole Role, int Percent, bool Charging);

    private sealed record ReadingDto(string? DeviceId, string? Name, DeviceKind Kind, List<ComponentDto>? Components, DateTimeOffset ReadAt);

    private sealed record Envelope(List<ReadingDto>? Readings);

    public static string Serialize(IReadOnlyList<BatteryReading> readings)
    {
        var dto = new Envelope(readings.Select(r => new ReadingDto(
            r.DeviceId, r.Name, r.Kind,
            r.Components.Select(c => new ComponentDto(c.Role, c.Percent, c.Charging)).ToList(),
            r.ReadAt)).ToList());
        return JsonSerializer.Serialize(dto, Options);
    }

    /// <summary>Throws <see cref="JsonException"/> on malformed input.</summary>
    public static IReadOnlyList<BatteryReading> Deserialize(string json)
    {
        var envelope = JsonSerializer.Deserialize<Envelope>(json, Options) ?? throw new JsonException("Empty battery payload.");
        return (envelope.Readings ?? []).Select(r =>
        {
            if (r.DeviceId is null || r.Name is null || r.Components is null) throw new JsonException("Incomplete battery reading.");
            return new BatteryReading(
                r.DeviceId, r.Name, r.Kind,
                r.Components.Select(c => new BatteryComponent(c.Role, c.Percent, c.Charging)).ToList(),
                r.ReadAt);
        }).ToList();
    }
}
