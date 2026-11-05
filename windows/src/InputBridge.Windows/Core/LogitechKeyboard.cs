using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

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
    private const ushort LogitechVendorId = 0x046D;
    private const ushort HidppUsagePage = 0xFF00;
    private const ushort HidppLongUsage = 0x0002;
    private const byte LongReportId = 0x11;
    private const byte SoftwareId = 0x0B;
    private const ushort FeatureDeviceName = 0x0005;
    private const ushort FeatureChangeHost = 0x1814;
    private static readonly TimeSpan ReplyTimeout = TimeSpan.FromMilliseconds(400);
    // A sleeping LIGHTSPEED keyboard answers its first request after roughly 1.2 s.
    private static readonly TimeSpan WakeTimeout = TimeSpan.FromMilliseconds(2000);
    private static readonly TimeSpan WakeGrace = TimeSpan.FromMilliseconds(150);

    /// <summary>Finds the first keyboard on a Logitech receiver whose name matches <paramref name="namePattern"/>.</summary>
    public static async Task<KeyboardHostState?> FindAsync(Regex namePattern, CancellationToken token = default)
    {
        var (state, channel) = await LocateAsync(namePattern, token);
        channel?.Dispose();
        return state;
    }

    /// <summary>
    /// Moves the keyboard from the receiver (LIGHTSPEED) to its other host (Bluetooth).
    /// Returns the keyboard that was switched, or null when it is not connected through a receiver.
    /// </summary>
    public static async Task<KeyboardHostState?> SwitchAwayFromReceiverAsync(Regex namePattern, CancellationToken token = default)
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

    /// <summary>Opens every receiver, wakes the paired devices at once and returns the matching keyboard with its open channel.</summary>
    private static async Task<(KeyboardHostState? State, HidppChannel? Channel)> LocateAsync(Regex namePattern, CancellationToken token)
    {
        var channels = FindReceiverPaths().Select(HidppChannel.TryOpen).OfType<HidppChannel>().ToList();
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

    /// <summary>Device paths of Logitech HID++ long-report collections (one per receiver).</summary>
    private static List<string> FindReceiverPaths()
    {
        var result = new List<string>();
        foreach (var path in Native.EnumerateHidPaths())
        {
            if (!path.Contains("vid_046d", StringComparison.OrdinalIgnoreCase)) continue;
            using var handle = Native.Open(path, 0);
            if (handle.IsInvalid) continue;
            if (!Native.TryGetInfo(handle, out var vendor, out var page, out var usage)) continue;
            if (vendor == LogitechVendorId && page == HidppUsagePage && usage == HidppLongUsage) result.Add(path);
        }
        return result;
    }

    /// <summary>One HID++ long-report collection with simple request/response matching.</summary>
    private sealed class HidppChannel : IDisposable
    {
        private readonly FileStream _stream;
        private readonly int _reportLength;
        private readonly CancellationTokenSource _readCancel = new();
        private readonly object _lock = new();
        private readonly SemaphoreSlim _requestGate = new(1, 1);
        private TaskCompletionSource<byte[]>? _pending;
        private Func<byte[], bool>? _matches;
        private Action<byte[]>? _collector;

        private HidppChannel(FileStream stream, int reportLength)
        {
            _stream = stream;
            _reportLength = reportLength;
            _ = Task.Run(ReadLoopAsync);
        }

        public static HidppChannel? TryOpen(string path)
        {
            var handle = Native.Open(path, Native.GenericRead | Native.GenericWrite);
            if (handle.IsInvalid) return null;
            if (!Native.TryGetReportLength(handle, out var length) || length < 7)
            {
                handle.Dispose();
                return null;
            }
            return new HidppChannel(new FileStream(handle, FileAccess.ReadWrite, 1, isAsync: true), length);
        }

        public async Task SendAsync(byte index, byte feature, byte function, byte[] parameters, CancellationToken token)
        {
            var data = new byte[_reportLength];
            data[0] = LongReportId;
            data[1] = index;
            data[2] = feature;
            data[3] = (byte)((function << 4) | SoftwareId);
            Array.Copy(parameters, 0, data, 4, Math.Min(parameters.Length, data.Length - 4));
            await _stream.WriteAsync(data, token);
        }

        /// <summary>
        /// Sends ROOT.getFeature to device slots 1-6 at once and returns the slots that answer.
        /// Waits for sleeping devices to wake, then a short grace period after the last reply.
        /// </summary>
        public async Task<List<byte>> FindOnlineDevicesAsync(ushort feature, CancellationToken token)
        {
            var online = new List<byte>();
            var firstReply = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_lock)
            {
                _collector = report =>
                {
                    if (report.Length < 5 || report[1] is < 1 or > 6) return;
                    var isReply = report[2] == 0x00 && report[3] == SoftwareId;
                    var isError = report[2] == 0xFF && report[3] == 0x00 && report[4] == SoftwareId;
                    if (!isReply && !isError) return;
                    if (!online.Contains(report[1])) online.Add(report[1]);
                    firstReply.TrySetResult();
                };
            }

            try
            {
                for (byte index = 1; index <= 6; index++)
                {
                    await SendAsync(index, 0x00, 0, [(byte)(feature >> 8), (byte)feature], token);
                }
                await Task.WhenAny(firstReply.Task, Task.Delay(WakeTimeout, token));
                if (firstReply.Task.IsCompleted) await Task.Delay(WakeGrace, token);
            }
            catch (IOException)
            {
                // Receiver unplugged.
            }
            finally
            {
                lock (_lock) { _collector = null; }
            }

            lock (_lock) { return online.OrderBy(x => x).ToList(); }
        }

        /// <summary>Sends a request and returns the reply parameters, or null on timeout/HID++ error.</summary>
        public async Task<byte[]?> RequestAsync(byte index, byte feature, byte function, byte[] parameters, CancellationToken token)
        {
            await _requestGate.WaitAsync(token);
            var functionByte = (byte)((function << 4) | SoftwareId);
            var completion = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
            try
            {
                lock (_lock)
                {
                    _pending = completion;
                    _matches = report => report.Length >= 5 && report[1] == index &&
                        ((report[2] == feature && report[3] == functionByte) ||                  // reply
                         (report[2] == 0xFF && report[3] == feature && report[4] == functionByte)); // HID++ 2.0 error
                }

                await SendAsync(index, feature, function, parameters, token);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                timeout.CancelAfter(ReplyTimeout);
                var report = await completion.Task.WaitAsync(timeout.Token);
                return report[2] == 0xFF ? null : report[4..];
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested)
            {
                return null;
            }
            catch (IOException)
            {
                return null;
            }
            finally
            {
                lock (_lock) { _pending = null; _matches = null; }
                _requestGate.Release();
            }
        }

        private async Task ReadLoopAsync()
        {
            var buffer = new byte[_reportLength];
            try
            {
                while (!_readCancel.IsCancellationRequested)
                {
                    var read = await _stream.ReadAsync(buffer, _readCancel.Token);
                    if (read <= 0) break;
                    if (buffer[0] != LongReportId) continue;
                    var report = buffer[..read];
                    lock (_lock)
                    {
                        _collector?.Invoke(report);
                        if (_matches?.Invoke(report) == true) _pending?.TrySetResult(report);
                    }
                }
            }
            catch
            {
                // Closed or device removed.
            }
        }

        public void Dispose()
        {
            _readCancel.Cancel();
            _stream.Dispose();
            _readCancel.Dispose();
        }
    }

    private static class Native
    {
        public const uint GenericRead = 0x80000000;
        public const uint GenericWrite = 0x40000000;
        private const uint FileShareReadWrite = 0x00000003;
        private const uint OpenExisting = 3;
        private const uint FileFlagOverlapped = 0x40000000;
        private const int DigcfPresent = 0x02;
        private const int DigcfDeviceInterface = 0x10;
        private const int HidpStatusSuccess = 0x00110000;

        public static SafeFileHandle Open(string path, uint access) =>
            CreateFile(path, access, FileShareReadWrite, IntPtr.Zero, OpenExisting, access == 0 ? 0 : FileFlagOverlapped, IntPtr.Zero);

        public static bool TryGetInfo(SafeFileHandle handle, out ushort vendor, out ushort usagePage, out ushort usage)
        {
            vendor = usagePage = usage = 0;
            var attributes = new HiddAttributes { Size = Marshal.SizeOf<HiddAttributes>() };
            if (!HidD_GetAttributes(handle, ref attributes)) return false;
            vendor = attributes.VendorId;
            if (!TryGetCaps(handle, out var caps)) return false;
            usagePage = caps.UsagePage;
            usage = caps.Usage;
            return true;
        }

        public static bool TryGetReportLength(SafeFileHandle handle, out int length)
        {
            length = 0;
            if (!TryGetCaps(handle, out var caps)) return false;
            length = Math.Max(caps.OutputReportByteLength, caps.InputReportByteLength);
            return true;
        }

        private static bool TryGetCaps(SafeFileHandle handle, out HidpCaps caps)
        {
            caps = default;
            if (!HidD_GetPreparsedData(handle, out var preparsed)) return false;
            try { return HidP_GetCaps(preparsed, out caps) == HidpStatusSuccess; }
            finally { HidD_FreePreparsedData(preparsed); }
        }

        public static IEnumerable<string> EnumerateHidPaths()
        {
            HidD_GetHidGuid(out var hidGuid);
            var set = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, DigcfPresent | DigcfDeviceInterface);
            if (set == IntPtr.Zero || set == new IntPtr(-1)) yield break;
            try
            {
                var data = new SpDeviceInterfaceData { Size = Marshal.SizeOf<SpDeviceInterfaceData>() };
                for (var i = 0; SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref hidGuid, i, ref data); i++)
                {
                    SetupDiGetDeviceInterfaceDetail(set, ref data, IntPtr.Zero, 0, out var required, IntPtr.Zero);
                    if (required <= 0) continue;
                    var detail = Marshal.AllocHGlobal(required);
                    try
                    {
                        // cbSize of SP_DEVICE_INTERFACE_DETAIL_DATA_W: 8 on 64-bit, 6 on 32-bit.
                        Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                        if (!SetupDiGetDeviceInterfaceDetail(set, ref data, detail, required, out _, IntPtr.Zero)) continue;
                        var path = Marshal.PtrToStringUni(detail + 4);
                        if (!string.IsNullOrEmpty(path)) yield return path;
                    }
                    finally
                    {
                        Marshal.FreeHGlobal(detail);
                    }
                }
            }
            finally
            {
                SetupDiDestroyDeviceInfoList(set);
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct HiddAttributes
        {
            public int Size;
            public ushort VendorId;
            public ushort ProductId;
            public ushort VersionNumber;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct HidpCaps
        {
            public ushort Usage;
            public ushort UsagePage;
            public ushort InputReportByteLength;
            public ushort OutputReportByteLength;
            public ushort FeatureReportByteLength;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
            public ushort[] Reserved;
            public ushort NumberLinkCollectionNodes;
            public ushort NumberInputButtonCaps;
            public ushort NumberInputValueCaps;
            public ushort NumberInputDataIndices;
            public ushort NumberOutputButtonCaps;
            public ushort NumberOutputValueCaps;
            public ushort NumberOutputDataIndices;
            public ushort NumberFeatureButtonCaps;
            public ushort NumberFeatureValueCaps;
            public ushort NumberFeatureDataIndices;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SpDeviceInterfaceData
        {
            public int Size;
            public Guid InterfaceClassGuid;
            public int Flags;
            public IntPtr Reserved;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);

        [DllImport("hid.dll")]
        private static extern void HidD_GetHidGuid(out Guid guid);

        [DllImport("hid.dll", SetLastError = true)]
        private static extern bool HidD_GetAttributes(SafeFileHandle handle, ref HiddAttributes attributes);

        [DllImport("hid.dll", SetLastError = true)]
        private static extern bool HidD_GetPreparsedData(SafeFileHandle handle, out IntPtr preparsed);

        [DllImport("hid.dll")]
        private static extern bool HidD_FreePreparsedData(IntPtr preparsed);

        [DllImport("hid.dll")]
        private static extern int HidP_GetCaps(IntPtr preparsed, out HidpCaps caps);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, IntPtr enumerator, IntPtr parent, int flags);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr info, ref Guid classGuid, int index, ref SpDeviceInterfaceData data);

        [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SpDeviceInterfaceData data, IntPtr detail, int detailSize, out int requiredSize, IntPtr info);

        [DllImport("setupapi.dll", SetLastError = true)]
        private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    }
}
