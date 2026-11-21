using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace InputBridge.Windows;

/// <summary>Draws a device's battery percentage as a tray icon (GDI+).</summary>
public static class BatteryIconRenderer
{
    private static readonly Color LowColor = Color.FromArgb(0xE8, 0x11, 0x23);
    private const int RemoteAlpha = 115; // ~45 % opacity

    // Bahnschrift ships with Windows 10 and later; its digits stay readable at 16 px. "100" uses the condensed cut.
    private static readonly string[] RegularFonts = ["Bahnschrift SemiBold", "Segoe UI Semibold", "Segoe UI"];
    private static readonly string[] CondensedFonts = ["Bahnschrift SemiBold Condensed", "Arial Narrow", "Segoe UI Semibold"];

    // Lightning bolt in a unit box (x right, y down).
    private static readonly PointF[] Bolt =
    [
        new(0.62f, 0.00f), new(0.06f, 0.58f), new(0.44f, 0.58f), new(0.30f, 1.00f),
        new(0.94f, 0.38f), new(0.56f, 0.38f), new(0.80f, 0.00f)
    ];

    public static Icon Render(BatteryReading reading, bool darkTaskbar, int size)
    {
        using var bitmap = Draw(BatteryIconVisual.Label(BatteryIconVisual.Primary(reading).Percent), BatteryIconVisual.Tone(reading), darkTaskbar, size);
        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    public static Bitmap Draw(string label, IconTone tone, bool darkTaskbar, int size)
    {
        var plain = darkTaskbar ? Color.White : Color.Black;
        var color = tone switch
        {
            IconTone.Low => LowColor,
            IconTone.Remote => Color.FromArgb(RemoteAlpha, plain),
            _ => plain
        };

        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.Clear(Color.Transparent);

        // While charging the digits sit lower and smaller so the bolt gets the top-right corner to itself.
        var charging = tone == IconTone.Charging;
        using (var text = LabelPath(label, size, charging ? 0.66f : 0.82f, alignBottom: charging))
        using (var brush = new SolidBrush(color))
        {
            g.FillPath(brush, text);
        }

        if (charging) DrawBolt(g, plain, size);
        return bitmap;
    }

    /// <summary>
    /// The label as an outline scaled to <paramref name="heightRatio"/> of the icon, squeezed sideways when it would be
    /// wider than the icon. The box is snapped to whole pixels so the digit edges stay crisp at 16 px.
    /// </summary>
    private static GraphicsPath LabelPath(string label, int size, float heightRatio, bool alignBottom)
    {
        var path = new GraphicsPath();
        using var family = PickFamily(label.Length >= 3 ? CondensedFonts : RegularFonts);
        using var format = new StringFormat(StringFormat.GenericTypographic);
        path.AddString(label, family, (int)FontStyle.Regular, 100f, PointF.Empty, format);

        var bounds = path.GetBounds();
        if (bounds.Width <= 0 || bounds.Height <= 0) return path;

        float height = MathF.Round(size * heightRatio);
        var scaleY = height / bounds.Height;
        var scaleX = Math.Min(scaleY, size / bounds.Width);
        var width = bounds.Width * scaleX;
        var left = MathF.Round((size - width) / 2f);
        var top = alignBottom ? size - height : MathF.Round((size - height) / 2f);

        using var transform = new Matrix();
        transform.Translate(left, top);
        transform.Scale(scaleX, scaleY);
        transform.Translate(-bounds.X, -bounds.Y);
        path.Transform(transform);
        return path;
    }

    /// <summary>A small bolt in the top-right corner, cut out of the digits with a transparent margin so both stay readable.</summary>
    private static void DrawBolt(Graphics g, Color color, int size)
    {
        var height = size * 0.5f;
        var width = height * 0.66f;
        var left = size - width;
        var points = Bolt.Select(p => new PointF(left + p.X * width, p.Y * height)).ToArray();

        using var bolt = new GraphicsPath();
        bolt.AddPolygon(points);

        using (var margin = (GraphicsPath)bolt.Clone())
        using (var pen = new Pen(Color.Black, Math.Max(2f, size / 8f)) { LineJoin = LineJoin.Round })
        using (var clear = new SolidBrush(Color.Transparent))
        {
            margin.Widen(pen);
            var mode = g.CompositingMode;
            g.CompositingMode = CompositingMode.SourceCopy;
            g.FillPath(clear, margin);
            g.FillPath(clear, bolt);
            g.CompositingMode = mode;
        }

        using var fill = new SolidBrush(color);
        g.FillPath(fill, bolt);
    }

    private static FontFamily PickFamily(IEnumerable<string> names)
    {
        foreach (var name in names)
        {
            try { return new FontFamily(name); }
            catch (ArgumentException) { /* not installed; try the next one */ }
        }
        return new FontFamily(System.Drawing.Text.GenericFontFamilies.SansSerif);
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}
