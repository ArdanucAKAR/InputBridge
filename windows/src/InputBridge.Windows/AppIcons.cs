using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Media = System.Windows.Media;

namespace InputBridge.Windows;

/// <summary>Builds the tray icon, its "update available" badge variant and the taskbar overlay.</summary>
internal static class AppIcons
{
    private static readonly Uri IconUri = new("pack://application:,,,/InputBridge;component/Assets/InputBridge.ico");
    private static readonly Color BadgeColor = Color.FromArgb(255, 234, 88, 12);

    public static Icon LoadTrayIcon()
    {
        var size = System.Windows.Forms.SystemInformation.SmallIconSize;
        var resource = System.Windows.Application.GetResourceStream(IconUri)
            ?? throw new InvalidOperationException("InputBridge.ico resource is missing.");
        using var stream = resource.Stream;
        return new Icon(stream, size);
    }

    /// <summary>Returns a copy of <paramref name="baseIcon"/> with an orange "!" badge in the lower-right corner.</summary>
    public static Icon CreateBadgedIcon(Icon baseIcon)
    {
        var size = baseIcon.Width;
        using var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.Clear(Color.Transparent);
            using (var source = baseIcon.ToBitmap())
            {
                g.DrawImage(source, new Rectangle(0, 0, size, size));
            }

            var diameter = Math.Max(7f, size * 0.58f);
            var badge = new RectangleF(size - diameter, size - diameter, diameter, diameter);
            using (var ring = new SolidBrush(Color.White))
            {
                var outline = RectangleF.Inflate(badge, 1f, 1f);
                g.FillEllipse(ring, outline);
            }
            using (var fill = new SolidBrush(BadgeColor))
            {
                g.FillEllipse(fill, badge);
            }

            // Exclamation mark: a bar and a dot, scaled to the badge.
            var barWidth = Math.Max(1.4f, diameter * 0.16f);
            var cx = badge.X + diameter / 2f;
            using var white = new SolidBrush(Color.White);
            g.FillRectangle(white, cx - barWidth / 2f, badge.Y + diameter * 0.2f, barWidth, diameter * 0.38f);
            g.FillEllipse(white, cx - barWidth / 2f, badge.Y + diameter * 0.66f, barWidth, barWidth);
        }

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

    /// <summary>Small vector badge shown over the taskbar button while an update is ready.</summary>
    public static Media.ImageSource CreateTaskbarOverlay()
    {
        var orange = new Media.SolidColorBrush(Media.Color.FromRgb(234, 88, 12));
        var group = new Media.DrawingGroup();
        group.Children.Add(new Media.GeometryDrawing(Media.Brushes.White, null, new Media.EllipseGeometry(new System.Windows.Point(8, 8), 8, 8)));
        group.Children.Add(new Media.GeometryDrawing(orange, null, new Media.EllipseGeometry(new System.Windows.Point(8, 8), 7, 7)));
        group.Children.Add(new Media.GeometryDrawing(Media.Brushes.White, null, new Media.RectangleGeometry(new System.Windows.Rect(7, 3.2, 2, 6), 0.8, 0.8)));
        group.Children.Add(new Media.GeometryDrawing(Media.Brushes.White, null, new Media.EllipseGeometry(new System.Windows.Point(8, 11.6), 1.1, 1.1)));
        var image = new Media.DrawingImage(group);
        image.Freeze();
        return image;
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}
