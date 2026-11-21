namespace InputBridge.Windows;

internal static class HidppReceivers
{
    private const ushort LogitechVendorId = 0x046D;
    private const ushort HidppUsagePage = 0xFF00;

    /// <summary>Device paths of Logitech HID++ collections with the given usage (0x0001 short, 0x0002 long).</summary>
    public static List<string> FindPaths(ushort usage)
    {
        var result = new List<string>();
        foreach (var path in HidNative.EnumerateHidPaths())
        {
            if (!path.Contains("vid_046d", StringComparison.OrdinalIgnoreCase)) continue;
            using var handle = HidNative.Open(path, 0);
            if (handle.IsInvalid) continue;
            if (!HidNative.TryGetInfo(handle, out var vendor, out var page, out var found)) continue;
            if (vendor == LogitechVendorId && page == HidppUsagePage && found == usage) result.Add(path);
        }
        return result;
    }
}
