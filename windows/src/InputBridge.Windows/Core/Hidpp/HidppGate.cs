namespace InputBridge.Windows;

/// <summary>Serialises HID++ conversations so the keyboard switch and battery reads never talk to a receiver at once.</summary>
internal static class HidppGate
{
    public static SemaphoreSlim Instance { get; } = new(1, 1);
}
