using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace InputBridge.Windows;

internal static class HidNative
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
