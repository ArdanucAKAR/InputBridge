using System.Buffers.Binary;
using System.IO;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using Windows.Storage.Streams;

namespace InputBridge.Windows;

public sealed record CameraDeviceInfo(string Id, string Name);

public sealed class CameraCaptureService : IAsyncDisposable
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private MediaCapture? _capture;
    private MediaFrameReader? _reader;
    private MediaFrameSourceGroup? _group;
    private byte[]? _latestJpeg;
    private uint _frameVersion;
    private int _encodingFlag;
    private TaskCompletionSource _frameSignal = NewSignal();

    public bool IsStreaming { get; private set; }
    public string? DeviceName { get; private set; }

    public static async Task<List<CameraDeviceInfo>> EnumerateAsync()
    {
        var groups = await MediaFrameSourceGroup.FindAllAsync();
        return groups
            .Select(group => new CameraDeviceInfo(group.Id, group.DisplayName))
            .OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public static string? PreferredDeviceId(IEnumerable<CameraDeviceInfo> devices)
    {
        var list = devices.ToList();
        return list.FirstOrDefault(item => item.Name.Contains("brio", StringComparison.OrdinalIgnoreCase))?.Id
            ?? list.FirstOrDefault(item => item.Name.Contains("logi", StringComparison.OrdinalIgnoreCase))?.Id
            ?? list.FirstOrDefault()?.Id;
    }

    public async Task StartAsync(string? deviceId)
    {
        await _gate.WaitAsync();
        try
        {
            if (IsStreaming) return;
            var groups = await MediaFrameSourceGroup.FindAllAsync();
            _group = SelectGroup(groups, deviceId) ?? throw new InvalidOperationException("No camera was found.");
            var sourceInfo = _group.SourceInfos.FirstOrDefault(info =>
                info.MediaStreamType == MediaStreamType.VideoRecord && info.SourceKind == MediaFrameSourceKind.Color)
                ?? throw new InvalidOperationException($"Camera '{_group.DisplayName}' has no video source.");

            _capture = new MediaCapture();
            await _capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                SourceGroup = _group,
                SharingMode = MediaCaptureSharingMode.ExclusiveControl,
                StreamingCaptureMode = StreamingCaptureMode.Video,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu
            });

            var source = _capture.FrameSources[sourceInfo.Id];
            var format = ChooseFormat(source);
            if (format is not null) await source.SetFormatAsync(format);

            _reader = await _capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Bgra8);
            _reader.FrameArrived += OnFrameArrived;
            var status = await _reader.StartAsync();
            if (status != MediaFrameReaderStartStatus.Success)
                throw new InvalidOperationException($"Could not start the camera ({status}).");

            DeviceName = _group.DisplayName;
            IsStreaming = true;
        }
        catch
        {
            await StopCoreAsync();
            throw;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task StopAsync()
    {
        await _gate.WaitAsync();
        try { await StopCoreAsync(); }
        finally { _gate.Release(); }
    }

    public async Task WriteStreamAsync(System.IO.Stream output, CancellationToken cancellationToken)
    {
        var header = new byte[4];
        uint lastSent = 0;
        while (!cancellationToken.IsCancellationRequested)
        {
            var jpeg = await WaitForJpegAsync(lastSent, cancellationToken);
            if (jpeg is null || jpeg.Length == 0) continue;
            lastSent = _frameVersion;
            BinaryPrimitives.WriteUInt32BigEndian(header, (uint)jpeg.Length);
            await output.WriteAsync(header, cancellationToken);
            await output.WriteAsync(jpeg, cancellationToken);
            await output.FlushAsync(cancellationToken);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        _gate.Dispose();
    }

    private async Task StopCoreAsync()
    {
        if (_reader is not null)
        {
            _reader.FrameArrived -= OnFrameArrived;
            try { await _reader.StopAsync(); } catch { /* already stopped */ }
            _reader.Dispose();
            _reader = null;
        }
        if (_capture is not null)
        {
            _capture.Dispose();
            _capture = null;
        }
        _group = null;
        IsStreaming = false;
        DeviceName = null;
        _latestJpeg = null;
    }

    private async Task<byte[]?> WaitForJpegAsync(uint lastSent, CancellationToken cancellationToken)
    {
        if (_latestJpeg is { Length: > 0 } && _frameVersion != lastSent) return _latestJpeg;
        var signal = _frameSignal;
        try { await signal.Task.WaitAsync(TimeSpan.FromMilliseconds(200), cancellationToken); }
        catch (TimeoutException) { }
        catch (OperationCanceledException) { throw; }
        return _latestJpeg;
    }

    private async void OnFrameArrived(MediaFrameReader sender, MediaFrameArrivedEventArgs args)
    {
        if (Interlocked.CompareExchange(ref _encodingFlag, 1, 0) != 0) return;
        using var frame = sender.TryAcquireLatestFrame();
        var bitmap = frame?.VideoMediaFrame?.SoftwareBitmap;
        if (bitmap is null)
        {
            Interlocked.Exchange(ref _encodingFlag, 0);
            return;
        }
        try
        {
            var jpeg = await EncodeJpegAsync(bitmap);
            if (jpeg.Length == 0) return;
            _latestJpeg = jpeg;
            _frameVersion++;
            var previous = _frameSignal;
            _frameSignal = NewSignal();
            previous.TrySetResult();
        }
        catch
        {
            // Drop a failed frame; the next one retries.
        }
        finally
        {
            Interlocked.Exchange(ref _encodingFlag, 0);
        }
    }

    private static async Task<byte[]> EncodeJpegAsync(SoftwareBitmap bitmap)
    {
        using var bgra = SoftwareBitmap.Convert(bitmap, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
        using var stream = new InMemoryRandomAccessStream();
        var quality = new BitmapPropertySet
        {
            ["ImageQuality"] = new BitmapTypedValue(0.7, global::Windows.Foundation.PropertyType.Single)
        };
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream, quality);
        encoder.SetSoftwareBitmap(bgra);
        if (bgra.PixelWidth > 1920 || bgra.PixelHeight > 1080)
        {
            encoder.BitmapTransform.ScaledWidth = 1920;
            encoder.BitmapTransform.ScaledHeight = 1080;
            encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
        }
        await encoder.FlushAsync();
        stream.Seek(0);
        var bytes = new byte[stream.Size];
        await stream.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
        return bytes;
    }

    private static MediaFrameSourceGroup? SelectGroup(IReadOnlyList<MediaFrameSourceGroup> groups, string? deviceId)
    {
        if (!string.IsNullOrWhiteSpace(deviceId))
            return groups.FirstOrDefault(group => group.Id == deviceId);
        var devices = groups.Select(group => new CameraDeviceInfo(group.Id, group.DisplayName)).ToList();
        var preferred = PreferredDeviceId(devices);
        return groups.FirstOrDefault(group => group.Id == preferred);
    }

    private static MediaFrameFormat? ChooseFormat(MediaFrameSource source)
    {
        static double Fps(MediaFrameFormat format) =>
            format.FrameRate.Denominator == 0 ? 0 : format.FrameRate.Numerator / (double)format.FrameRate.Denominator;

        var formats = source.SupportedFormats;
        return formats
            .Where(format => format.VideoFormat.Width >= 1280 && format.VideoFormat.Height >= 720)
            .OrderBy(format => Math.Abs((int)format.VideoFormat.Width - 1920) + Math.Abs((int)format.VideoFormat.Height - 1080))
            .ThenByDescending(Fps)
            .FirstOrDefault()
            ?? formats.OrderByDescending(format => format.VideoFormat.Width * format.VideoFormat.Height).FirstOrDefault();
    }

    private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
}
