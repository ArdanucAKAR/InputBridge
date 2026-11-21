using Xunit;

namespace InputBridge.Windows.Tests;

public class TrayBatteryIconsCallbackTests
{
    // NOTIFYICON_VERSION_4 callbacks: the event is the low word of lParam, the icon id the high word.
    private const int NIN_SELECT = 0x0400, NIN_KEYSELECT = 0x0401, WM_CONTEXTMENU = 0x007B;
    private const int WM_MOUSEMOVE = 0x0200, WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202;

    private static TrayIconAction Classify(int message) => TrayBatteryIcons.Classify((nint)((7 << 16) | message));

    [Fact] public void Left_click_opens_the_window() => Assert.Equal(TrayIconAction.Open, Classify(NIN_SELECT));
    [Fact] public void Keyboard_select_opens_the_window() => Assert.Equal(TrayIconAction.Open, Classify(NIN_KEYSELECT));
    [Fact] public void Right_click_shows_the_menu() => Assert.Equal(TrayIconAction.ContextMenu, Classify(WM_CONTEXTMENU));

    // Version 4 sends NIN_SELECT after the raw button messages; acting on those too would open the window twice.
    [Theory]
    [InlineData(WM_MOUSEMOVE)]
    [InlineData(WM_LBUTTONDOWN)]
    [InlineData(WM_LBUTTONUP)]
    public void Raw_mouse_messages_do_nothing(int message) => Assert.Equal(TrayIconAction.None, Classify(message));
}
