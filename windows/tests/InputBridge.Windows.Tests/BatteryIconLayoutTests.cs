using System.Drawing;
using Xunit;

namespace InputBridge.Windows.Tests;

public class BatteryIconLayoutTests
{
    public static TheoryData<int, bool> Sizes => new()
    {
        { 16, false }, { 16, true }, { 20, false }, { 24, true }, { 32, false }, { 32, true }
    };

    [Theory, MemberData(nameof(Sizes))]
    public void Boxes_StayInsideIcon(int size, bool charging)
    {
        var b = BatteryIconLayout.Compute(size, charging);
        AssertInside(b.Glyph, size);
        AssertInside(b.Digits, size);
        if (b.Bolt is { } bolt) AssertInside(bolt, size);
    }

    [Theory, MemberData(nameof(Sizes))]
    public void Glyph_SitsAboveDigits(int size, bool charging)
    {
        var b = BatteryIconLayout.Compute(size, charging);
        Assert.True(b.Glyph.Bottom <= b.Digits.Top);
    }

    [Theory, MemberData(nameof(Sizes))]
    public void Digits_TakeAtLeastHalfTheHeight(int size, bool charging) =>
        Assert.True(BatteryIconLayout.Compute(size, charging).Digits.Height >= size * 0.5f);

    [Theory, MemberData(nameof(Sizes))]
    public void Boxes_AreSnappedToWholePixels(int size, bool charging)
    {
        var b = BatteryIconLayout.Compute(size, charging);
        AssertWholePixels(b.Glyph);
        AssertWholePixels(b.Digits);
        if (b.Bolt is { } bolt) AssertWholePixels(bolt);
    }

    [Fact]
    public void Sixteen_Pixels_KeepsAOnePixelGapBetweenGlyphAndDigits()
    {
        var b = BatteryIconLayout.Compute(16, false);
        Assert.Equal(1f, b.Digits.Top - b.Glyph.Bottom);
    }

    [Fact]
    public void Bolt_OnlyWhenCharging_BesideTheGlyph()
    {
        Assert.Null(BatteryIconLayout.Compute(16, false).Bolt);
        var b = BatteryIconLayout.Compute(16, true);
        Assert.NotNull(b.Bolt);
        Assert.True(b.Bolt!.Value.Left >= b.Glyph.Right && b.Bolt.Value.Bottom <= b.Digits.Top);
    }

    private static void AssertInside(RectangleF box, int size)
    {
        Assert.True(box.Left >= 0 && box.Top >= 0, $"{box} starts outside the icon");
        Assert.True(box.Right <= size && box.Bottom <= size, $"{box} ends outside the {size} px icon");
        Assert.True(box.Width > 0 && box.Height > 0, $"{box} is empty");
    }

    private static void AssertWholePixels(RectangleF box)
    {
        foreach (var v in new[] { box.X, box.Y, box.Width, box.Height })
            Assert.Equal(MathF.Round(v), v);
    }
}
