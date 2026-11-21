using System.Text;
using Xunit;

namespace InputBridge.Windows.Tests;

public class HidppDeviceQueriesTests
{
    private const string LongName = "G915 TKL LIGHTSPEED Wireless RGB Mechanical Gaming Keyboard";

    /// <summary>A fake DEVICE_NAME feature at index 5: fn 0 = length, fn 1 = 16-byte chunk from the given offset.</summary>
    private static Task<byte[]?> NameFeature(byte feature, byte function, byte[] parameters)
    {
        var bytes = Encoding.ASCII.GetBytes(LongName);
        byte[]? reply = (feature, function) switch
        {
            (5, 0) => [(byte)bytes.Length, .. new byte[15]],
            (5, 1) => bytes.Skip(parameters[0]).Take(16).Concat(new byte[16]).Take(16).ToArray(),
            _ => null,
        };
        return Task.FromResult(reply);
    }

    [Fact] public async Task DeviceName_AssemblesChunksAndTrimsToLength() =>
        Assert.Equal(LongName, await HidppDeviceQueries.DeviceNameAsync(NameFeature, 5));

    [Fact] public async Task DeviceName_NullWhenAChunkFails() =>
        Assert.Null(await HidppDeviceQueries.DeviceNameAsync((f, fn, p) => fn == 0 ? Task.FromResult<byte[]?>([20]) : Task.FromResult<byte[]?>(null), 5));

    [Fact] public async Task FeatureIndex_SendsFeatureIdToRoot()
    {
        byte[]? sent = null;
        var index = await HidppDeviceQueries.FeatureIndexAsync((f, fn, p) => { sent = [f, fn, .. p]; return Task.FromResult<byte[]?>([0x06, 0x00, 0x00]); }, 0x1001);
        Assert.Equal((byte)6, index);
        Assert.Equal(new byte[] { 0x00, 0x00, 0x10, 0x01 }, sent);
    }

    [Fact] public async Task FeatureIndex_ZeroMeansUnsupported() =>
        Assert.Null(await HidppDeviceQueries.FeatureIndexAsync((f, fn, p) => Task.FromResult<byte[]?>([0x00, 0x00, 0x00]), 0x1004));

    [Fact] public async Task FeatureIndex_NoAnswerIsNull() =>
        Assert.Null(await HidppDeviceQueries.FeatureIndexAsync((f, fn, p) => Task.FromResult<byte[]?>(null), 0x1004));
}
