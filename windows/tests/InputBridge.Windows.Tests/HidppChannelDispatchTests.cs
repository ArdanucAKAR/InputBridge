using Xunit;

namespace InputBridge.Windows.Tests;

public class HidppChannelDispatchTests
{
    [Fact]
    public void Throwing_handler_does_not_stop_later_handlers()
    {
        byte[]? received = null;
        Action<byte[]>? handlers = _ => throw new InvalidOperationException("boom");
        handlers += report => received = report;
        var report = new byte[] { 0x11, 0x01 };

        HidppChannel.Dispatch(handlers, report);

        Assert.Same(report, received);
    }

    [Fact]
    public void Null_handlers_are_ignored() => HidppChannel.Dispatch(null, [0x11]);
}
