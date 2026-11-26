using InputBridge.Windows;
using Xunit;

namespace InputBridge.Windows.Tests;

public class HidppCollectionPlanTests
{
    [Fact] public void Receiver_ScansOnlyOnFirstOpen()
    {
        Assert.True(HidppCollectionPlan.ShouldScan(isReceiver: true, firstOpenThisSession: true));
        Assert.False(HidppCollectionPlan.ShouldScan(isReceiver: true, firstOpenThisSession: false));
    }

    [Fact] public void DirectDevice_ScansOnEveryOpen() =>
        Assert.True(HidppCollectionPlan.ShouldScan(isReceiver: false, firstOpenThisSession: false));
}
