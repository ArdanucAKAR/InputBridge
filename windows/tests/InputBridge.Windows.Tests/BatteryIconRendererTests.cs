using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using Xunit;

namespace InputBridge.Windows.Tests;

public class BatteryIconRendererTests
{
    [Theory]
    [InlineData(DeviceKind.Keyboard, 16)]
    [InlineData(DeviceKind.Mouse, 16)]
    [InlineData(DeviceKind.Headset, 16)]
    [InlineData(DeviceKind.Other, 16)]
    [InlineData(DeviceKind.Trackpad, 20)]
    [InlineData(DeviceKind.Keyboard, 32)]
    public void Draw_PutsInkInGlyphAndDigitBoxes(DeviceKind kind, int size)
    {
        using var bitmap = BatteryIconRenderer.Draw("62", IconTone.Normal, kind, darkTaskbar: true, size);
        var boxes = BatteryIconLayout.Compute(size, charging: false);

        Assert.True(HasInk(bitmap, boxes.Glyph), "no glyph ink");
        Assert.True(HasInk(bitmap, boxes.Digits), "no digit ink");
    }

    [Fact]
    public void Draw_DarkTaskbarIsWhite_LightTaskbarIsBlack()
    {
        using var dark = BatteryIconRenderer.Draw("62", IconTone.Normal, DeviceKind.Mouse, darkTaskbar: true, 16);
        using var light = BatteryIconRenderer.Draw("62", IconTone.Normal, DeviceKind.Mouse, darkTaskbar: false, 16);

        Assert.True(HasPixel(dark, c => c.A > 200 && c.R > 200 && c.G > 200 && c.B > 200));
        Assert.True(HasPixel(light, c => c.A > 200 && c.R < 60 && c.G < 60 && c.B < 60));
    }

    [Fact]
    public void Draw_LowIsRed()
    {
        using var bitmap = BatteryIconRenderer.Draw("9", IconTone.Low, DeviceKind.Mouse, darkTaskbar: true, 16);
        Assert.True(HasPixel(bitmap, c => c.R > 200 && c.G < 80 && c.A > 128));
    }

    [Fact]
    public void Draw_LowGlyphIsRedToo()
    {
        using var bitmap = BatteryIconRenderer.Draw("9", IconTone.Low, DeviceKind.Keyboard, darkTaskbar: true, 16);
        var glyph = BatteryIconLayout.Compute(16, charging: false).Glyph;
        Assert.True(HasPixel(bitmap, glyph, c => c.R > 200 && c.G < 80 && c.A > 128));
        Assert.False(HasPixel(bitmap, glyph, c => c.A > 128 && c.G > 200));
    }

    [Fact]
    public void Draw_ChargingHasInkInBoltBox()
    {
        using var bitmap = BatteryIconRenderer.Draw("98", IconTone.Charging, DeviceKind.Keyboard, darkTaskbar: true, 16);
        var boxes = BatteryIconLayout.Compute(16, charging: true);

        Assert.True(HasInk(bitmap, boxes.Bolt!.Value), "no bolt ink");
        Assert.True(HasInk(bitmap, boxes.Glyph), "no glyph ink");
        Assert.True(HasInk(bitmap, boxes.Digits), "no digit ink");
    }

    [Theory]
    [InlineData(16)]
    [InlineData(24)]
    public void Draw_HundredFitsTheIcon(int size)
    {
        using var bitmap = BatteryIconRenderer.Draw("100", IconTone.Normal, DeviceKind.Keyboard, darkTaskbar: true, size);
        var digits = BatteryIconLayout.Compute(size, charging: false).Digits;
        Assert.True(HasInk(bitmap, digits));
    }

    [Fact]
    public void Draw_WritesPreviewPngs()
    {
        var folder = Path.Combine(Path.GetTempPath(), "InputBridge-icon-preview");
        Directory.CreateDirectory(folder);
        const int Zoom = 8;

        var kinds = new[] { DeviceKind.Keyboard, DeviceKind.Mouse, DeviceKind.Headset, DeviceKind.Other };
        var tones = new (IconTone Tone, string Label)[]
        {
            (IconTone.Normal, "62"), (IconTone.Low, "9"), (IconTone.Charging, "98"), (IconTone.Normal, "100")
        };
        var sizes = new[] { 16, 20, 24, 32 };
        var written = new List<string>();

        foreach (var dark in new[] { true, false })
        {
            var background = dark ? Color.FromArgb(0x20, 0x20, 0x20) : Color.FromArgb(0xF3, 0xF3, 0xF3);
            var theme = dark ? "dark" : "light";
            foreach (var size in sizes)
            {
                // One contact sheet per size and theme: rows are kinds, columns are tones.
                var cell = size * Zoom + Zoom * 2;
                using var sheet = new Bitmap(cell * tones.Length, cell * kinds.Length, PixelFormat.Format32bppArgb);
                using var sheetGraphics = Graphics.FromImage(sheet);
                sheetGraphics.Clear(background);
                sheetGraphics.InterpolationMode = InterpolationMode.NearestNeighbor;
                sheetGraphics.PixelOffsetMode = PixelOffsetMode.Half;

                for (var row = 0; row < kinds.Length; row++)
                for (var column = 0; column < tones.Length; column++)
                {
                    var (tone, label) = tones[column];
                    using var icon = BatteryIconRenderer.Draw(label, tone, kinds[row], dark, size);
                    using var zoomed = new Bitmap(size * Zoom, size * Zoom, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(zoomed))
                    {
                        g.Clear(background);
                        g.InterpolationMode = InterpolationMode.NearestNeighbor;
                        g.PixelOffsetMode = PixelOffsetMode.Half;
                        g.DrawImage(icon, new Rectangle(0, 0, size * Zoom, size * Zoom));
                    }

                    var file = Path.Combine(folder, $"{kinds[row]}-{tone}-{label}-{size}-{theme}.png".ToLowerInvariant());
                    zoomed.Save(file, ImageFormat.Png);
                    written.Add(file);
                    sheetGraphics.DrawImage(zoomed, column * cell + Zoom, row * cell + Zoom);
                }

                var sheetFile = Path.Combine(folder, $"sheet-{size}-{theme}.png");
                sheet.Save(sheetFile, ImageFormat.Png);
                written.Add(sheetFile);
            }
        }

        Assert.All(written, file => Assert.True(File.Exists(file), file));
    }

    private static bool HasInk(Bitmap bitmap, RectangleF box) => HasPixel(bitmap, box, c => c.A > 128);

    private static bool HasPixel(Bitmap bitmap, Func<Color, bool> match) =>
        HasPixel(bitmap, new RectangleF(0, 0, bitmap.Width, bitmap.Height), match);

    /// <summary>Whether a pixel whose centre lies inside <paramref name="box"/> matches.</summary>
    private static bool HasPixel(Bitmap bitmap, RectangleF box, Func<Color, bool> match)
    {
        for (var y = 0; y < bitmap.Height; y++)
        for (var x = 0; x < bitmap.Width; x++)
        {
            if (!box.Contains(x + 0.5f, y + 0.5f)) continue;
            if (match(bitmap.GetPixel(x, y))) return true;
        }
        return false;
    }
}
