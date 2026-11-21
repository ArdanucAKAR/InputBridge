using System.Text.Json;
using System.Text.Json.Serialization;

namespace InputBridge.Windows;

/// <summary>JSON wire format of battery readings, shared with the Mac app (see shared/fixtures/battery-readings.json).</summary>
public static class BatteryWire
{
    private const int MaxReadings = 8;
    private const int MaxComponents = 3;
    private const int MaxTextLength = 128;

    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) }
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
        var items = envelope.Readings ?? [];
        if (items.Count > MaxReadings) throw new JsonException("Too many battery readings.");
        return items.Select(r =>
        {
            if (r.DeviceId is null || r.Name is null || r.Components is null) throw new JsonException("Incomplete battery reading.");
            if (r.DeviceId.Length is 0 or > MaxTextLength || r.Name.Length is 0 or > MaxTextLength)
                throw new JsonException("Invalid battery device id or name.");
            if (!Enum.IsDefined(r.Kind)) throw new JsonException("Unknown device kind.");
            if (r.Components.Count is 0 or > MaxComponents) throw new JsonException("Invalid battery component count.");
            if (r.Components.Any(c => c.Percent is < 0 or > 100 || !Enum.IsDefined(c.Role)))
                throw new JsonException("Invalid battery component.");
            return new BatteryReading(
                r.DeviceId, r.Name, r.Kind,
                r.Components.Select(c => new BatteryComponent(c.Role, c.Percent, c.Charging)).ToList(),
                r.ReadAt);
        }).ToList();
    }
}
