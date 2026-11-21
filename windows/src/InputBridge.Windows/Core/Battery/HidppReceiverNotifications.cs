namespace InputBridge.Windows;

/// <summary>Pure helpers for HID++ receiver registers and notifications.</summary>
internal static class HidppReceiverNotifications
{
    private const byte ShortReportId = 0x10;
    private const byte LongReportId = 0x11;
    private const byte ReceiverIndex = 0xFF;
    private const byte ConnectionSubId = 0x41;
    public const byte SetRegister = 0x80;
    public const byte GetRegister = 0x81;
    private const byte NotificationFlagsRegister = 0x00;
    private const byte ConnectionStateRegister = 0x02;
    private const byte ReportConnectedDevices = 0x02;
    private const byte LinkNotEstablished = 0x40;
    private const byte WirelessNotifications = 0x01;

    /// <summary>Parses a device connection notification <c>[0x10, index, 0x41, protocol, flags, wpidLo, wpidHi]</c>.</summary>
    public static (byte Index, bool Linked)? ParseConnection(ReadOnlySpan<byte> shortReport)
    {
        if (shortReport.Length < 7 || shortReport[0] != ShortReportId || shortReport[2] != ConnectionSubId) return null;
        return (shortReport[1], (shortReport[4] & LinkNotEstablished) == 0);
    }

    /// <summary>GET_REGISTER for the receiver's notification flags (register 0x00).</summary>
    public static byte[] ReadNotificationFlagsRequest() =>
        [ShortReportId, ReceiverIndex, GetRegister, NotificationFlagsRegister, 0x00, 0x00, 0x00];

    /// <summary>
    /// SET_REGISTER for the notification flags: the current three flag bytes with only the wireless-notification
    /// bit added, so flags other software (G HUB) enabled stay set.
    /// </summary>
    public static byte[] WriteNotificationFlagsRequest(ReadOnlySpan<byte> current) =>
        [ShortReportId, ReceiverIndex, SetRegister, NotificationFlagsRegister, current[0], (byte)(current[1] | WirelessNotifications), current[2]];

    /// <summary>True when the wireless-notification bit is already set in the three flag bytes.</summary>
    public static bool WirelessNotificationsEnabled(ReadOnlySpan<byte> current) => (current[1] & WirelessNotifications) != 0;

    /// <summary>
    /// Recognises the register 0x00 read reply <c>[0x10, 0xFF, 0x81, 0x00, r0, r1, r2]</c> and returns the flag bytes.
    /// </summary>
    public static byte[]? ParseNotificationFlagsReply(ReadOnlySpan<byte> shortReport) =>
        IsRegisterReply(shortReport, GetRegister, NotificationFlagsRegister) ? shortReport[4..7].ToArray() : null;

    /// <summary>Recognises the register 0x00 write acknowledgement <c>[0x10, 0xFF, 0x80, 0x00, …]</c>.</summary>
    public static bool IsNotificationFlagsWriteReply(ReadOnlySpan<byte> shortReport) =>
        IsRegisterReply(shortReport, SetRegister, NotificationFlagsRegister);

    /// <summary>
    /// SET_REGISTER 0x02 = 0x02: the receiver reports the link state of every paired device it knows as 0x41
    /// notifications. It answers from its own state, so it sends nothing over the air and wakes no device.
    /// </summary>
    public static byte[] ReportConnectedDevicesRequest() =>
        [ShortReportId, ReceiverIndex, SetRegister, ConnectionStateRegister, ReportConnectedDevices, 0x00, 0x00];

    /// <summary>Recognises the register 0x02 write acknowledgement <c>[0x10, 0xFF, 0x80, 0x02, …]</c>.</summary>
    public static bool IsReportConnectedDevicesReply(ReadOnlySpan<byte> shortReport) =>
        IsRegisterReply(shortReport, SetRegister, ConnectionStateRegister);

    /// <summary>Recognises the HID++ 1.0 error <c>[0x10, 0xFF, 0x8F, subId, register, …]</c> for a register access.</summary>
    public static bool IsRegisterError(ReadOnlySpan<byte> shortReport, byte subId, byte register = NotificationFlagsRegister) =>
        shortReport.Length >= 7 && shortReport[0] == ShortReportId && shortReport[1] == ReceiverIndex &&
        shortReport[2] == 0x8F && shortReport[3] == subId && shortReport[4] == register;

    /// <summary>A HID++ 2.0 event (software id 0) from the battery feature at <paramref name="batteryFeatureIndex"/>.</summary>
    public static bool IsBatteryEvent(ReadOnlySpan<byte> longReport, byte batteryFeatureIndex) =>
        longReport.Length >= 5 && longReport[0] == LongReportId && batteryFeatureIndex != 0 &&
        longReport[2] == batteryFeatureIndex && (longReport[3] & 0x0F) == 0;

    private static bool IsRegisterReply(ReadOnlySpan<byte> shortReport, byte subId, byte register) =>
        shortReport.Length >= 7 && shortReport[0] == ShortReportId && shortReport[1] == ReceiverIndex &&
        shortReport[2] == subId && shortReport[3] == register;
}
