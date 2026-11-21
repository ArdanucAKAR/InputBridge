using Xunit;

namespace InputBridge.Windows.Tests;

public class HidppChannelMatchingTests
{
    private static readonly byte[] Reply = [0x11, 0x01, 0x05, 0x1C, 0x00, 0x00];
    private static readonly byte[] OtherSoftwareId = [0x11, 0x01, 0x05, 0x1B, 0x00, 0x00];
    private static readonly byte[] Error = [0x11, 0x01, 0xFF, 0x05, 0x1C, 0x02];
    private static readonly byte[] Short = [0x11, 0x01, 0x05, 0x1C];

    [Fact]
    public void IsReplyTo_matches_index_feature_and_function_byte()
    {
        Assert.True(HidppMatch.IsReplyTo(Reply, 1, 5, 0x1C));
    }

    [Fact]
    public void IsReplyTo_rejects_other_software_id()
    {
        Assert.False(HidppMatch.IsReplyTo(OtherSoftwareId, 1, 5, 0x1C));
    }

    [Fact]
    public void IsErrorFor_matches_hidpp2_error_report()
    {
        Assert.True(HidppMatch.IsErrorFor(Error, 1, 5, 0x1C));
    }

    [Fact]
    public void Short_reports_match_nothing()
    {
        Assert.False(HidppMatch.IsReplyTo(Short, 1, 5, 0x1C));
        Assert.False(HidppMatch.IsErrorFor(Short, 1, 5, 0x1C));
    }
}
