using System.Drawing;

namespace InputBridge.Windows;

/// <summary>Where a tray icon draws its parts, in pixels: the device glyph, the percentage and, while charging, the bolt.</summary>
public readonly record struct IconBoxes(RectangleF Glyph, RectangleF Digits, RectangleF? Bolt);

/// <summary>
/// Splits a square tray icon into a top row for the device glyph (and the bolt while charging) and a larger bottom
/// row for the percentage. Every box is snapped to whole pixels so 1 px strokes and digit edges stay crisp at 16 px.
/// </summary>
public static class BatteryIconLayout
{
    /// <summary>Share of the icon height the top (glyph) row takes.</summary>
    private const float GlyphRowRatio = 0.4f;

    /// <summary>Share of the icon width the bolt takes at the right of the top row while charging.</summary>
    private const float BoltWidthRatio = 0.4f;

    public static IconBoxes Compute(int size, bool charging)
    {
        // 16 px: glyph 6, gap 1, digits 9. 20: 8/1/11. 24: 10/2/12. 32: 13/2/17.
        var glyphHeight = MathF.Round(size * GlyphRowRatio);
        var gap = MathF.Max(1f, MathF.Round(size / 16f));
        var digitsTop = glyphHeight + gap;
        var digits = new RectangleF(0, digitsTop, size, size - digitsTop);

        if (!charging) return new IconBoxes(new RectangleF(0, 0, size, glyphHeight), digits, null);

        var boltWidth = MathF.Round(size * BoltWidthRatio);
        var glyph = new RectangleF(0, 0, size - boltWidth, glyphHeight);
        var bolt = new RectangleF(size - boltWidth, 0, boltWidth, glyphHeight);
        return new IconBoxes(glyph, digits, bolt);
    }
}
