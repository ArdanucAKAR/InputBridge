using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace InputBridge.Windows;

/// <summary>What a notification-icon callback asks for.</summary>
public enum TrayIconAction { None, Open, ContextMenu }

/// <summary>
/// One notification-area icon per visible battery device, created with <c>Shell_NotifyIcon</c> and a stable GUID so a
/// pin survives restarts. An icon whose device disappears is hidden, not deleted, so it keeps its place.
/// Must be created and used on the UI thread.
/// </summary>
public sealed class TrayBatteryIcons : IDisposable
{
    private const int CallbackMessage = 0x8000 + 1; // WM_APP + 1
    private const int WM_CONTEXTMENU = 0x007B;
    private const int NIN_SELECT = 0x0400, NIN_KEYSELECT = 0x0401;
    private const int NIM_ADD = 0, NIM_MODIFY = 1, NIM_DELETE = 2, NIM_SETVERSION = 4;
    private const int NIF_MESSAGE = 0x01, NIF_ICON = 0x02, NIF_TIP = 0x04, NIF_STATE = 0x08, NIF_GUID = 0x20, NIF_SHOWTIP = 0x80;
    private const int NIS_HIDDEN = 0x01;
    private const int NOTIFYICON_VERSION_4 = 4;
    private const int SM_CXSMICON = 49;

    private readonly string _exePath;
    private readonly MessageWindow _window;
    private readonly Dictionary<Guid, Entry> _entries = [];
    private IReadOnlyList<BatteryReading> _lastVisible = [];
    private bool _lastDark = true;
    private bool _disposed;

    public TrayBatteryIcons(string exePath)
    {
        _exePath = exePath;
        _window = new MessageWindow(this);
    }

    /// <summary>Right-click (or the menu key) on any battery icon; the point is the cursor position in screen coordinates.</summary>
    public event Action<Point>? ContextMenuRequested;

    /// <summary>Left click (or Space/Enter) on any battery icon.</summary>
    public event Action? OpenRequested;

    /// <summary>Windows draws the taskbar dark when <c>SystemUsesLightTheme</c> is 0 (also the default when the value is missing).</summary>
    public static bool IsTaskbarDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is not int light || light == 0;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"Battery tray: reading the taskbar theme failed: {ex.Message}");
            return true;
        }
    }

    public void Update(IReadOnlyList<BatteryReading> visible, bool darkTaskbar)
    {
        if (_disposed) return;
        _lastVisible = visible;
        _lastDark = darkTaskbar;
        var size = IconSize();

        var shown = new HashSet<Guid>();
        foreach (var reading in visible)
        {
            var guid = BatteryIconVisual.IconGuid(_exePath, reading.DeviceId);
            if (!shown.Add(guid)) continue;
            if (!_entries.TryGetValue(guid, out var entry)) _entries[guid] = entry = new Entry(guid);
            try { Show(entry, reading, darkTaskbar, size); }
            catch (Exception ex) { Debug.WriteLine($"Battery tray: showing {reading.DeviceId} failed: {ex.Message}"); }
        }

        foreach (var entry in _entries.Values.Where(e => !shown.Contains(e.Guid) && e.Added && !e.Hidden))
        {
            Hide(entry);
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        foreach (var entry in _entries.Values)
        {
            if (entry.Added)
            {
                var data = NewData(entry.Guid);
                Shell_NotifyIconW(NIM_DELETE, ref data);
            }
            entry.Icon?.Dispose();
        }
        _entries.Clear();
        _window.DestroyHandle();
    }

    private void Show(Entry entry, BatteryReading reading, bool dark, int size)
    {
        var tip = BatteryIconVisual.Tooltip(reading);
        var key = $"{BatteryIconVisual.Label(BatteryIconVisual.Primary(reading).Percent)}|{BatteryIconVisual.Tone(reading)}|{reading.Kind}|{dark}|{size}|{tip}";
        if (entry.Added && !entry.Hidden && entry.Key == key) return;

        var icon = entry.Key == key && entry.Icon is not null ? entry.Icon : BatteryIconRenderer.Render(reading, dark, size);
        var data = NewData(entry.Guid);
        data.uFlags |= NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_STATE | NIF_SHOWTIP;
        data.uCallbackMessage = CallbackMessage;
        data.hWnd = _window.Handle;
        data.hIcon = icon.Handle;
        data.szTip = tip;
        data.dwState = 0;
        data.dwStateMask = NIS_HIDDEN;

        // A modify fails when Explorer lost the icon without telling us; adding it again covers that case too.
        var ok = entry.Added && Shell_NotifyIconW(NIM_MODIFY, ref data);
        if (!ok) ok = Add(ref data);

        if (!ok)
        {
            if (!ReferenceEquals(icon, entry.Icon)) icon.Dispose();
            entry.Added = false;
            entry.Key = "";
            return;
        }
        // The shell keeps its own copy of the icon, so the previous one can go now.
        if (!ReferenceEquals(icon, entry.Icon)) entry.Icon?.Dispose();
        entry.Icon = icon;
        entry.Key = key;
        entry.Added = true;
        entry.Hidden = false;
    }

    /// <summary>NIM_ADD; a GUID can be left registered (e.g. after a crash), so delete it and retry once before giving up.</summary>
    private static bool Add(ref NotifyIconData data)
    {
        if (!Shell_NotifyIconW(NIM_ADD, ref data))
        {
            var stale = NewData(data.guidItem);
            Shell_NotifyIconW(NIM_DELETE, ref stale);
            if (!Shell_NotifyIconW(NIM_ADD, ref data))
            {
                Debug.WriteLine($"Battery tray: adding icon {data.guidItem} failed (error {Marshal.GetLastWin32Error()}).");
                return false;
            }
        }
        var version = NewData(data.guidItem);
        version.uTimeoutOrVersion = NOTIFYICON_VERSION_4;
        if (!Shell_NotifyIconW(NIM_SETVERSION, ref version))
        {
            Debug.WriteLine($"Battery tray: setting version 4 on {data.guidItem} failed.");
        }
        return true;
    }

    private static void Hide(Entry entry)
    {
        var data = NewData(entry.Guid);
        data.uFlags |= NIF_STATE;
        data.dwState = NIS_HIDDEN;
        data.dwStateMask = NIS_HIDDEN;
        if (!Shell_NotifyIconW(NIM_MODIFY, ref data))
        {
            // Explorer may still show it (a modify can fail for an icon it has); delete it so no stale level stays
            // up. It is added again when the device comes back.
            Debug.WriteLine($"Battery tray: hiding icon {entry.Guid} failed; deleting it.");
            var delete = NewData(entry.Guid);
            Shell_NotifyIconW(NIM_DELETE, ref delete);
            entry.Added = false;
            entry.Key = "";
        }
        entry.Hidden = true;
    }

    private void OnTaskbarCreated()
    {
        // Explorer restarted: every icon is gone on its side.
        foreach (var entry in _entries.Values)
        {
            entry.Added = false;
            entry.Hidden = false;
            entry.Key = "";
        }
        Update(_lastVisible, _lastDark);
    }

    /// <summary>
    /// NOTIFYICON_VERSION_4: the low word of lParam is the event. A left click arrives as the raw button messages and
    /// then NIN_SELECT; only NIN_SELECT counts, so one click opens the window once.
    /// </summary>
    internal static TrayIconAction Classify(IntPtr lParam) => (int)(lParam.ToInt64() & 0xFFFF) switch
    {
        NIN_SELECT or NIN_KEYSELECT => TrayIconAction.Open,
        WM_CONTEXTMENU => TrayIconAction.ContextMenu,
        _ => TrayIconAction.None,
    };

    private void OnCallback(IntPtr lParam)
    {
        switch (Classify(lParam))
        {
            case TrayIconAction.Open:
                OpenRequested?.Invoke();
                break;
            case TrayIconAction.ContextMenu:
                // The cursor position is DPI-virtualised for this process like the main tray icon's menu; the
                // anchor in wParam is not.
                var point = Forms.Cursor.Position;
                SetForegroundWindow(_window.Handle); // so the menu closes when the user clicks elsewhere
                ContextMenuRequested?.Invoke(point);
                break;
        }
    }

    private static int IconSize()
    {
        try
        {
            var size = GetSystemMetricsForDpi(SM_CXSMICON, GetDpiForSystem());
            if (size > 0) return size;
        }
        catch (EntryPointNotFoundException) { /* older than Windows 10 1607 */ }
        return Forms.SystemInformation.SmallIconSize.Width;
    }

    private static NotifyIconData NewData(Guid guid) => new()
    {
        cbSize = Marshal.SizeOf<NotifyIconData>(),
        uFlags = NIF_GUID,
        guidItem = guid,
        szTip = "",
        szInfo = "",
        szInfoTitle = ""
    };

    private sealed class Entry(Guid guid)
    {
        public Guid Guid { get; } = guid;
        public Icon? Icon { get; set; }
        public string Key { get; set; } = "";
        public bool Added { get; set; }
        public bool Hidden { get; set; }
    }

    /// <summary>
    /// Hidden top-level window for icon callbacks. Not a message-only (HWND_MESSAGE) window: those never receive the
    /// broadcast TaskbarCreated message that tells us Explorer restarted.
    /// </summary>
    private sealed class MessageWindow : Forms.NativeWindow
    {
        private const int WS_EX_TOOLWINDOW = 0x80;
        private const uint MSGFLT_ALLOW = 1;
        private readonly TrayBatteryIcons _owner;
        private readonly int _taskbarCreated;

        public MessageWindow(TrayBatteryIcons owner)
        {
            _owner = owner;
            _taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
            CreateHandle(new Forms.CreateParams { Caption = "InputBridge battery icons", ExStyle = WS_EX_TOOLWINDOW });
            // If InputBridge runs elevated (e.g. relaunched by the installer), let Explorer's messages through UIPI.
            ChangeWindowMessageFilterEx(Handle, (uint)_taskbarCreated, MSGFLT_ALLOW, IntPtr.Zero);
            ChangeWindowMessageFilterEx(Handle, CallbackMessage, MSGFLT_ALLOW, IntPtr.Zero);
        }

        protected override void WndProc(ref Forms.Message m)
        {
            try
            {
                if (m.Msg == CallbackMessage) { _owner.OnCallback(m.LParam); return; }
                if (_taskbarCreated != 0 && m.Msg == _taskbarCreated) { _owner.OnTaskbarCreated(); return; }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"Battery tray: message {m.Msg:X} failed: {ex.Message}");
                return;
            }
            base.WndProc(ref m);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public int cbSize;
        public IntPtr hWnd;
        public int uID;
        public int uFlags;
        public int uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public int dwState;
        public int dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public int uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public int dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIconW(int message, ref NotifyIconData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int RegisterWindowMessageW(string name);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ChangeWindowMessageFilterEx(IntPtr hwnd, uint message, uint action, IntPtr filterStatus);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();

    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);
}
