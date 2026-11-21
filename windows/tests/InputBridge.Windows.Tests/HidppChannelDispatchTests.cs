using System.IO;
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

public class HidppChannelCompletionTests
{
    [Fact]
    public async Task Completion_finishes_when_the_read_loop_ends_without_dispose()
    {
        // An empty file reads as end-of-stream at once, like a removed device whose read loop stops.
        var path = Path.GetTempFileName();
        try
        {
            var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite, 1, useAsync: true);
            using var channel = new HidppChannel(path, stream, 7, 0x0C);
            await channel.Completion.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally
        {
            File.Delete(path);
        }
    }
}
