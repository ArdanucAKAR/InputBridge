using System.Text;

namespace InputBridge.Windows;

/// <summary>
/// Sends one HID++ 2.0 request to a fixed device (feature index, function, parameters) and returns the reply
/// parameters, or null on timeout or HID++ error.
/// </summary>
internal delegate Task<byte[]?> HidppDeviceRequest(byte feature, byte function, byte[] parameters);

/// <summary>Device queries shared by the keyboard switch and battery reading, so both see the same device names.</summary>
internal static class HidppDeviceQueries
{
    private const byte RootFeature = 0x00;

    /// <summary>ROOT.getFeature; null when the device does not answer or lacks the feature (index 0).</summary>
    public static async Task<byte?> FeatureIndexAsync(HidppDeviceRequest request, ushort feature)
    {
        var reply = await request(RootFeature, 0, [(byte)(feature >> 8), (byte)feature]);
        return reply is { Length: > 0 } && reply[0] != 0 ? reply[0] : null;
    }

    /// <summary>DEVICE_NAME (0x0005): fn 0 gives the length, fn 1 returns the name in chunks from a character offset.</summary>
    public static async Task<string?> DeviceNameAsync(HidppDeviceRequest request, byte nameFeature)
    {
        var count = await request(nameFeature, 0, []);
        if (count is not { Length: > 0 }) return null;
        var length = count[0];
        var name = new StringBuilder();
        while (name.Length < length)
        {
            var chunk = await request(nameFeature, 1, [(byte)name.Length]);
            if (chunk is null) return null;
            var text = Encoding.ASCII.GetString(chunk).TrimEnd('\0');
            if (text.Length == 0) break;
            name.Append(text);
        }
        return name.ToString()[..Math.Min(name.Length, length)];
    }
}
