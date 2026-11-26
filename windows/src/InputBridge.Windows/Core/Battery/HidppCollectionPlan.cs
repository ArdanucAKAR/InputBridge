namespace InputBridge.Windows;

/// <summary>Decides what to do when a Logitech HID++ collection is opened.</summary>
internal static class HidppCollectionPlan
{
    /// <summary>
    /// Whether to run the slot ping scan. A receiver is scanned only on its first open in the session, as the scan wakes
    /// sleeping devices. A direct (cabled) device never confirmed the connected-devices query and has no link
    /// notifications, so it is scanned on every open.
    /// </summary>
    public static bool ShouldScan(bool isReceiver, bool firstOpenThisSession) => !isReceiver || firstOpenThisSession;
}
