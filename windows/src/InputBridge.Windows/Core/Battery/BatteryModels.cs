namespace InputBridge.Windows;

public enum DeviceKind { Keyboard, Mouse, Headset, Trackpad, Other }

public enum ComponentRole { Main, Left, Right, Case }

public sealed record BatteryComponent(ComponentRole Role, int Percent, bool Charging);

public sealed record BatteryReading(
    string DeviceId,
    string Name,
    DeviceKind Kind,
    IReadOnlyList<BatteryComponent> Components,
    DateTimeOffset ReadAt,
    bool Remote = false);

public static class BatteryIds
{
    public const string SharedKeyboard = "logitech-keyboard";
}
