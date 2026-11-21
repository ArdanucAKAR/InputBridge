using System.Text.RegularExpressions;

namespace InputBridge.Windows;

/// <summary>What device discovery learned about one receiver slot.</summary>
internal sealed record LogitechDeviceInfo(string Name, DeviceKind Kind, ushort BatteryFeature, byte BatteryFeatureIndex, bool SocSupported);

/// <summary>
/// Link and battery state of the devices on one receiver. Pure state machine without I/O or locking;
/// the caller serialises access.
/// </summary>
internal sealed class LogitechDeviceTracker
{
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(30);
    private readonly SortedDictionary<byte, Slot> _slots = new();

    /// <summary>A device came online. Its old value is dropped; returns the slots that need a full read now.</summary>
    public IReadOnlyList<byte> OnLinked(byte index)
    {
        var slot = SlotFor(index);
        slot.Linked = true;
        slot.Battery = null;
        return [index];
    }

    /// <summary>A device went offline (asleep, switched away or off); it is hidden at once.</summary>
    public void OnLinkLost(byte index)
    {
        var slot = SlotFor(index);
        slot.Linked = false;
        slot.Battery = null;
    }

    public void OnDeviceInfo(byte index, string name, DeviceKind kind, ushort batteryFeature, byte batteryFeatureIndex, bool socSupported) =>
        SlotFor(index).Info = new LogitechDeviceInfo(name, kind, batteryFeature, batteryFeatureIndex, socSupported);

    public void OnBattery(byte index, BatteryComponent component, DateTimeOffset at)
    {
        var slot = SlotFor(index);
        if (slot.Linked) slot.Battery = (component, at);
    }

    /// <summary>
    /// A read was started. A refresh that fails (no answer) waits another 30 minutes instead of being retried every tick.
    /// </summary>
    public void OnReadAttempt(byte index, DateTimeOffset at) => SlotFor(index).LastAttempt = at;

    /// <summary>The discovered device in the slot, or null before discovery.</summary>
    public LogitechDeviceInfo? Info(byte index) => _slots.TryGetValue(index, out var slot) ? slot.Info : null;

    /// <summary>
    /// Online devices whose last reading or last read attempt is at least 30 minutes old. This includes a device whose
    /// first read failed: it is known to be online, so it is retried every 30 minutes rather than left blank until it re-links.
    /// </summary>
    public IReadOnlyList<byte> DueForRefresh(DateTimeOffset now) =>
        _slots.Where(pair => pair.Value.Linked && Latest(pair.Value.Battery?.At, pair.Value.LastAttempt) is { } last &&
                             now - last >= RefreshInterval)
            .Select(pair => pair.Key)
            .ToList();

    /// <summary>Online devices with a reading; the shared keyboard gets <see cref="BatteryIds.SharedKeyboard"/>.</summary>
    public IReadOnlyList<BatteryReading> Readings(Regex sharedKeyboardPattern) =>
        _slots.Values
            .Where(slot => slot.Linked && slot.Info is not null && slot.Battery is not null)
            .Select(slot =>
            {
                var info = slot.Info!;
                var (component, at) = slot.Battery!.Value;
                var id = sharedKeyboardPattern.IsMatch(info.Name) ? BatteryIds.SharedKeyboard : "logitech:" + info.Name;
                return new BatteryReading(id, info.Name, info.Kind, [component], at);
            })
            .ToList();

    private static DateTimeOffset? Latest(DateTimeOffset? a, DateTimeOffset? b) => a is null ? b : b is null ? a : a > b ? a : b;

    private Slot SlotFor(byte index)
    {
        if (!_slots.TryGetValue(index, out var slot)) _slots[index] = slot = new Slot();
        return slot;
    }

    private sealed class Slot
    {
        public bool Linked;
        public LogitechDeviceInfo? Info;
        public (BatteryComponent Component, DateTimeOffset At)? Battery;
        public DateTimeOffset? LastAttempt;
    }
}
