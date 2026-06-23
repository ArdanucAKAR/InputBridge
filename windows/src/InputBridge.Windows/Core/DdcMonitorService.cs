using System.Runtime.InteropServices;

namespace InputBridge.Windows;

public sealed class DdcMonitorService
{
    private const byte InputSourceVcp = 0x60;

    public List<PhysicalMonitorInfo> Enumerate()
    {
        var monitors = Acquire();
        try
        {
            var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            var results = new List<PhysicalMonitorInfo>();
            foreach (var monitor in monitors)
            {
                var description = monitor.Description.Trim();
                counts[description] = counts.TryGetValue(description, out var current) ? current + 1 : 1;
                var key = $"{description}#{counts[description]}";
                results.Add(new PhysicalMonitorInfo(key, description, ReadInput(monitor.Handle)));
            }
            return results;
        }
        finally { Destroy(monitors); }
    }

    public List<MonitorActionResult> Apply(IEnumerable<MonitorProfileSetting> settings, ProfileMode mode)
    {
        var selected = settings.Where(x => x.Enabled).ToDictionary(x => x.Key, StringComparer.OrdinalIgnoreCase);
        if (selected.Count == 0) return [];
        var monitors = Acquire();
        try
        {
            var counts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            var result = new List<MonitorActionResult>();
            foreach (var monitor in monitors)
            {
                var description = monitor.Description.Trim();
                counts[description] = counts.TryGetValue(description, out var current) ? current + 1 : 1;
                var key = $"{description}#{counts[description]}";
                if (!selected.TryGetValue(key, out var target)) continue;
                var input = mode == ProfileMode.Windows ? target.WindowsInput : target.MacInput;
                var before = ReadInput(monitor.Handle);
                var ok = SetVCPFeature(monitor.Handle, InputSourceVcp, input);
                result.Add(new MonitorActionResult(key, description, before, input, ok, ok ? null : "SetVCPFeature returned false."));
                Thread.Sleep(650);
            }
            return result;
        }
        finally { Destroy(monitors); }
    }

    private static List<PhysicalHandle> Acquire()
    {
        var result = new List<PhysicalHandle>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hMonitor, _, _, _) =>
        {
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMonitor, out var count) || count == 0) return true;
            var physical = new PHYSICAL_MONITOR[count];
            if (!GetPhysicalMonitorsFromHMONITOR(hMonitor, count, physical)) return true;
            foreach (var item in physical) result.Add(new PhysicalHandle(item.hPhysicalMonitor, item.szPhysicalMonitorDescription));
            return true;
        }, IntPtr.Zero);
        return result;
    }

    private static void Destroy(List<PhysicalHandle> handles)
    {
        if (handles.Count == 0) return;
        var native = handles.Select(x => new PHYSICAL_MONITOR { hPhysicalMonitor = x.Handle, szPhysicalMonitorDescription = x.Description }).ToArray();
        DestroyPhysicalMonitors((uint)native.Length, native);
    }

    private static int? ReadInput(IntPtr handle)
    {
        return GetVCPFeatureAndVCPFeatureReply(handle, InputSourceVcp, out _, out var current, out _) ? (int)current : null;
    }

    private sealed record PhysicalHandle(IntPtr Handle, string Description);
    public sealed record PhysicalMonitorInfo(string Key, string Description, int? CurrentInput);

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
    }

    [DllImport("User32.dll")] private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);
    [DllImport("Dxva2.dll")] private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);
    [DllImport("Dxva2.dll", CharSet = CharSet.Unicode)] private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] PHYSICAL_MONITOR[] physicalMonitors);
    [DllImport("Dxva2.dll")] private static extern bool DestroyPhysicalMonitors(uint count, [In] PHYSICAL_MONITOR[] physicalMonitors);
    [DllImport("Dxva2.dll")] private static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr handle, byte code, out uint type, out uint current, out uint maximum);
    [DllImport("Dxva2.dll")] private static extern bool SetVCPFeature(IntPtr handle, byte code, uint value);
}
