using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace InputBridge.Windows;

/// <summary>Draws a device's battery percentage as a tray icon (GDI+).</summary>
public static class BatteryIconRenderer
{
    private static readonly Color LowColor = Color.FromArgb(0xE8, 0x11, 0x23);

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
        var label = BatteryIconVisual.Label(BatteryIconVisual.Primary(reading).Percent);
        using var bitmap = Draw(label, BatteryIconVisual.Tone(reading), reading.Kind, darkTaskbar, size);
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

    /// <summary>
    /// The device glyph in the top row and the percentage large below it (see <see cref="BatteryIconLayout"/>).
    /// White on a dark taskbar, black on a light one; glyph and digits turn red when low. While charging the bolt
    /// takes the right of the top row.
    /// </summary>
    public static Bitmap Draw(string label, IconTone tone, DeviceKind kind, bool darkTaskbar, int size)
    {
        var plain = darkTaskbar ? Color.White : Color.Black;
        var color = tone switch
        {
            IconTone.Low => LowColor,
            _ => plain
        };
        var charging = tone == IconTone.Charging;
        var boxes = BatteryIconLayout.Compute(size, charging);

        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.Clear(Color.Transparent);

        using (var text = LabelPath(label, boxes.Digits))
        using (var brush = new SolidBrush(color))
        {
            g.FillPath(brush, text);
        }

        DrawGlyph(g, kind, boxes.Glyph, color, StrokeWidth(size));
        if (boxes.Bolt is { } bolt) DrawBolt(g, plain, bolt, boxes.Digits.Top);
        return bitmap;
    }

    /// <summary>
    /// The label as an outline as tall as <paramref name="box"/>, centred in it and squeezed sideways when it would be
    /// wider. The left edge is snapped to whole pixels so the digit edges stay crisp at 16 px.
    /// </summary>
    private static GraphicsPath LabelPath(string label, RectangleF box)
    {
        var path = new GraphicsPath();
        using var family = PickFamily(label.Length >= 3 ? CondensedFonts : RegularFonts);
        using var format = new StringFormat(StringFormat.GenericTypographic);
        path.AddString(label, family, (int)FontStyle.Regular, 100f, PointF.Empty, format);

        var bounds = path.GetBounds();
        if (bounds.Width <= 0 || bounds.Height <= 0) return path;

        var scaleY = box.Height / bounds.Height;
        var scaleX = Math.Min(scaleY, box.Width / bounds.Width);
        var width = bounds.Width * scaleX;
        var left = box.Left + MathF.Round((box.Width - width) / 2f);

        using var transform = new Matrix();
        transform.Translate(left, box.Top);
        transform.Scale(scaleX, scaleY);
        transform.Translate(-bounds.X, -bounds.Y);
        path.Transform(transform);
        return path;
    }

    /// <summary>A small bolt in <paramref name="box"/>, cut out of its surroundings above the digits with a transparent margin.</summary>
    private static void DrawBolt(Graphics g, Color color, RectangleF box, float digitsTop)
    {
        // Wider than the bolt's natural 0.66 so its diagonals stay solid at 16 px.
        var height = box.Height;
        var width = Math.Min(box.Width, height * 0.9f);
        var left = box.Left + (box.Width - width) / 2f;
        var points = Bolt.Select(p => new PointF(left + p.X * width, box.Top + p.Y * height)).ToArray();

        using var bolt = new GraphicsPath();
        bolt.AddPolygon(points);

        using (var margin = (GraphicsPath)bolt.Clone())
        using (var pen = new Pen(Color.Black, Math.Max(2f, height / 3f)) { LineJoin = LineJoin.Round })
        using (var clear = new SolidBrush(Color.Transparent))
        {
            margin.Widen(pen);
            var mode = g.CompositingMode;
            var clip = g.Clip;
            // The margin only separates the bolt from the glyph; it must not bite into the digits below.
            g.SetClip(new RectangleF(0, 0, g.VisibleClipBounds.Width, digitsTop));
            g.CompositingMode = CompositingMode.SourceCopy;
            g.FillPath(clear, margin);
            g.FillPath(clear, bolt);
            g.CompositingMode = mode;
            g.Clip = clip;
            clip.Dispose();
        }

        // Under 8 px tall (16 px icons) the bolt's thin diagonals fade to grey, so a thin outline in the same colour fattens them.
        using var fill = new SolidBrush(color);
        g.FillPath(fill, bolt);
        if (height < 8)
        {
            using var edge = new Pen(color, 0.6f) { LineJoin = LineJoin.Round };
            g.DrawPath(edge, bolt);
        }
    }

    // Device glyphs. Each is drawn in a shape box of the given aspect (width / height) fitted into the glyph box; the
    // positions below are fractions of that shape box (x right, y down), like the bolt.
    private const float KeyboardAspect = 2.0f;
    private const float MouseAspect = 0.62f;
    private const float MouseLineEnd = 0.45f;    // the centre line runs from the top down to here
    private const float HeadsetAspect = 1.2f;
    private const float HeadsetBandEnd = 0.62f;  // the band arc comes down to here at both sides
    private const float HeadsetCupTop = 0.5f;
    private const float HeadsetCupWidth = 0.25f;
    private const float BatteryAspect = 2.0f;
    private const float BatteryNubTop = 0.3f;    // the terminal spans 0.3 to 0.7 of the height

    /// <summary>
    /// Glyph strokes are about a twelfth of the icon, rounded down so the small glyphs keep an open interior:
    /// 1 px at 16 and 20, 2 px at 24 and 32.
    /// </summary>
    private static int StrokeWidth(int size) => Math.Max(1, (int)(size / 12f));

    private static void DrawGlyph(Graphics g, DeviceKind kind, RectangleF box, Color color, int stroke)
    {
        var aspect = kind switch
        {
            DeviceKind.Keyboard => KeyboardAspect,
            DeviceKind.Mouse => MouseAspect,
            DeviceKind.Headset => HeadsetAspect,
            _ => BatteryAspect
        };
        // The mouse needs room for a pixel of space on each side of its centre line, whatever its aspect.
        var minWidth = kind == DeviceKind.Mouse ? 3 * stroke + 2 : 0;
        var shape = ShapeBox(box, aspect, stroke, minWidth);

        using var pen = new Pen(color, stroke) { LineJoin = LineJoin.Round };
        using var brush = new SolidBrush(color);
        switch (kind)
        {
            case DeviceKind.Keyboard: DrawKeyboard(g, shape, stroke, pen, brush); break;
            case DeviceKind.Mouse: DrawMouse(g, shape, stroke, pen); break;
            case DeviceKind.Headset: DrawHeadset(g, shape, stroke, pen, brush); break;
            default: DrawBattery(g, shape, stroke, pen, brush); break;
        }
    }

    /// <summary>
    /// The largest box of <paramref name="aspect"/> that fits in <paramref name="box"/>, in whole pixels and centred.
    /// Its width has the stroke's parity so a centre line lands on whole pixels and the glyph stays symmetric, and is at
    /// least <paramref name="minWidth"/> when the box allows.
    /// </summary>
    private static Rectangle ShapeBox(RectangleF box, float aspect, int stroke, int minWidth)
    {
        var height = (int)box.Height;
        var ideal = MathF.Max(height * aspect, minWidth);
        if (ideal > box.Width)
        {
            ideal = box.Width;
            height = Math.Min(height, (int)MathF.Round(ideal / aspect));
        }
        // The nearest width of the stroke's parity, still inside the box.
        var width = stroke + 2 * (int)MathF.Round((ideal - stroke) / 2f, MidpointRounding.AwayFromZero);
        if (width > box.Width) width -= 2;

        var left = (int)box.Left + ((int)box.Width - width) / 2;
        var top = (int)box.Top + ((int)box.Height - height) / 2;
        return new Rectangle(left, top, width, height);
    }

    /// <summary>The shape box shrunk by half a stroke, so a pen of that width draws its outline inside the box.</summary>
    private static RectangleF Inset(Rectangle shape, int stroke)
    {
        var half = stroke / 2f;
        return new RectangleF(shape.X + half, shape.Y + half, shape.Width - stroke, shape.Height - stroke);
    }

    /// <summary>A rounded outline with one row of keys, a stroke apart.</summary>
    private static void DrawKeyboard(Graphics g, Rectangle shape, int stroke, Pen pen, Brush brush)
    {
        var outline = Inset(shape, stroke);
        using (var body = RoundedRectangle(outline, Math.Max(stroke, shape.Height * 0.2f)))
        {
            g.DrawPath(pen, body);
        }

        // Keys are a stroke wide and a stroke apart, a stroke inside the outline at both ends. The row is centred in
        // the interior with at least a pixel clear above and below, so it gets shorter when the keyboard is squeezed.
        var span = shape.Width - 4 * stroke;
        var keys = Math.Max(1, (span + stroke) / (2 * stroke));
        var used = keys * 2 * stroke - stroke;
        var left = shape.X + 2 * stroke + (span - used) / 2;
        var interior = shape.Height - 2 * stroke;
        var keyHeight = Math.Min(stroke, interior - 2);
        if (keyHeight < 1) return;
        var top = shape.Y + stroke + (interior - keyHeight) / 2;
        for (var i = 0; i < keys; i++)
        {
            g.FillRectangle(brush, left + i * 2 * stroke, top, stroke, keyHeight);
        }
    }

    /// <summary>
    /// A capsule with a centre line from the top: the split between the two buttons. With 1 px strokes (16 and 20 px)
    /// a line across closes the buttons off, which keeps the small, round mouse from reading as a power symbol; with
    /// thicker strokes it would crowd the interior into a face.
    /// </summary>
    private static void DrawMouse(Graphics g, Rectangle shape, int stroke, Pen pen)
    {
        var outline = Inset(shape, stroke);
        using (var body = RoundedRectangle(outline, outline.Width / 2f))
        {
            g.DrawPath(pen, body);
        }

        var x = shape.X + shape.Width / 2f;
        var y = shape.Y + MathF.Round(shape.Height * MouseLineEnd - stroke / 2f) + stroke / 2f;
        g.DrawLine(pen, x, outline.Top, x, y);
        if (stroke == 1) g.DrawLine(pen, outline.Left, y, outline.Right, y);
    }

    /// <summary>A band arc over the top with a filled cup at each end.</summary>
    private static void DrawHeadset(Graphics g, Rectangle shape, int stroke, Pen pen, Brush brush)
    {
        var outline = Inset(shape, stroke);
        var bandEnd = shape.Y + shape.Height * HeadsetBandEnd;
        g.DrawArc(pen, outline.X, outline.Y, outline.Width, 2 * (bandEnd - outline.Y), 180, 180);

        var cupWidth = Math.Max(2 * stroke, (int)MathF.Round(shape.Width * HeadsetCupWidth));
        var cupTop = shape.Y + (int)MathF.Round(shape.Height * HeadsetCupTop);
        var cupHeight = shape.Bottom - cupTop;
        g.FillRectangle(brush, shape.X, cupTop, cupWidth, cupHeight);
        g.FillRectangle(brush, shape.Right - cupWidth, cupTop, cupWidth, cupHeight);
    }

    /// <summary>A battery outline with its terminal on the right; used for trackpads and other devices.</summary>
    private static void DrawBattery(Graphics g, Rectangle shape, int stroke, Pen pen, Brush brush)
    {
        var nub = stroke;
        var body = Inset(new Rectangle(shape.X, shape.Y, shape.Width - nub, shape.Height), stroke);
        g.DrawRectangle(pen, body.X, body.Y, body.Width, body.Height);

        var inset = (int)MathF.Round(shape.Height * BatteryNubTop);
        g.FillRectangle(brush, shape.Right - nub, shape.Y + inset, nub, shape.Height - 2 * inset);
    }

    private static GraphicsPath RoundedRectangle(RectangleF r, float radius)
    {
        var d = Math.Min(2 * radius, Math.Min(r.Width, r.Height));
        var path = new GraphicsPath();
        path.AddArc(r.Left, r.Top, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Top, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
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
