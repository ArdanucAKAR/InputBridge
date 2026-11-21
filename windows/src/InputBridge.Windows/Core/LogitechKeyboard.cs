using System.Text;
using System.Text.RegularExpressions;

namespace InputBridge.Windows;

/// <summary>A Logitech keyboard reached through a LIGHTSPEED/Unifying receiver, with its HID++ host state.</summary>
public sealed record KeyboardHostState(string Name, byte DeviceIndex, byte ChangeHostFeature, int HostCount, int CurrentHost);

/// <summary>
/// Minimal HID++ 2.0 client for switching a multi-host Logitech keyboard (G915/G913) between its hosts.
/// The keyboard is only reachable here while it is connected through the receiver plugged into this PC
/// (LIGHTSPEED); in Bluetooth mode the Mac has to switch it.
/// </summary>
public static class LogitechKeyboard
{
    private const byte SoftwareId = 0x0B;
    private const ushort FeatureDeviceName = 0x0005;
    private const ushort FeatureChangeHost = 0x1814;

    /// <summary>Finds the first keyboard on a Logitech receiver whose name matches <paramref name="namePattern"/>.</summary>
    public static async Task<KeyboardHostState?> FindAsync(Regex namePattern, CancellationToken token = default)
    {
        await HidppGate.Instance.WaitAsync(token);
        try
        {
            var (state, channel) = await LocateAsync(namePattern, token);
            channel?.Dispose();
            return state;
        }
        finally
        {
            HidppGate.Instance.Release();
        }
    }

    /// <summary>
    /// Moves the keyboard from the receiver (LIGHTSPEED) to its other host (Bluetooth).
    /// Returns the keyboard that was switched, or null when it is not connected through a receiver.
    /// </summary>
    public static async Task<KeyboardHostState?> SwitchAwayFromReceiverAsync(Regex namePattern, CancellationToken token = default)
    {
        await HidppGate.Instance.WaitAsync(token);
        try
        {
            var (state, channel) = await LocateAsync(namePattern, token);
            if (state is null || channel is null) return null;
            using (channel)
            {
                if (state.HostCount != 2)
                    throw new InvalidOperationException($"{state.Name} reports {state.HostCount} hosts; only two-host keyboards are supported.");

                var target = (byte)(state.CurrentHost == 0 ? 1 : 0);
                // setCurrentHost (function 1). The keyboard leaves immediately, so no reply is expected.
                await channel.SendAsync(state.DeviceIndex, state.ChangeHostFeature, 1, [target], token);
                return state;
            }
        }
        finally
        {
            HidppGate.Instance.Release();
        }
    }

    /// <summary>Opens every receiver, wakes the paired devices at once and returns the matching keyboard with its open channel.</summary>
    private static async Task<(KeyboardHostState? State, HidppChannel? Channel)> LocateAsync(Regex namePattern, CancellationToken token)
    {
        var channels = HidppReceivers.FindPaths(0x0002).Select(path => HidppChannel.TryOpen(path, SoftwareId)).OfType<HidppChannel>().ToList();
        try
        {
            var online = await Task.WhenAll(channels.Select(channel => channel.FindOnlineDevicesAsync(FeatureDeviceName, token)));
            for (var i = 0; i < channels.Count; i++)
            {
                foreach (var index in online[i])
                {
                    var state = await QueryAsync(channels[i], index, namePattern, token);
                    if (state is null) continue;
                    var found = channels[i];
                    channels.RemoveAt(i);
                    return (state, found);
                }
            }
            return (null, null);
        }
        finally
        {
            foreach (var channel in channels) channel.Dispose();
        }
    }

    private static async Task<KeyboardHostState?> QueryAsync(HidppChannel channel, byte index, Regex namePattern, CancellationToken token)
    {
        // ROOT.getFeature(DEVICE_NAME) doubles as a ping: offline slots simply do not answer.
        var nameFeature = await GetFeatureIndexAsync(channel, index, FeatureDeviceName, token);
        if (nameFeature is null or 0) return null;

        var name = await GetDeviceNameAsync(channel, index, nameFeature.Value, token);
        if (name is null || !namePattern.IsMatch(name)) return null;

        var changeHost = await GetFeatureIndexAsync(channel, index, FeatureChangeHost, token);
        if (changeHost is null or 0) return null;

        var info = await channel.RequestAsync(index, changeHost.Value, 0, [], token);
        if (info is null) return null;
        return new KeyboardHostState(name, index, changeHost.Value, info[0], info[1]);
    }

    private static async Task<byte?> GetFeatureIndexAsync(HidppChannel channel, byte index, ushort feature, CancellationToken token)
    {
        var reply = await channel.RequestAsync(index, 0x00, 0, [(byte)(feature >> 8), (byte)feature], token);
        return reply?[0];
    }

    private static async Task<string?> GetDeviceNameAsync(HidppChannel channel, byte index, byte feature, CancellationToken token)
    {
        var count = await channel.RequestAsync(index, feature, 0, [], token);
        if (count is null) return null;
        var length = count[0];
        var name = new StringBuilder();
        while (name.Length < length)
        {
            var chunk = await channel.RequestAsync(index, feature, 1, [(byte)name.Length], token);
            if (chunk is null) return null;
            var text = Encoding.ASCII.GetString(chunk).TrimEnd('\0');
            if (text.Length == 0) break;
            name.Append(text);
        }
        return name.ToString()[..Math.Min(name.Length, length)];
    }
}
