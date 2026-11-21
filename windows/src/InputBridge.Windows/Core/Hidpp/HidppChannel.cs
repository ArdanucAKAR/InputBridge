using System.IO;

namespace InputBridge.Windows;

/// <summary>Recognises the reply or HID++ 2.0 error report that answers one request.</summary>
internal static class HidppMatch
{
    public static bool IsReplyTo(ReadOnlySpan<byte> report, byte index, byte feature, byte functionByte) =>
        report.Length >= 5 && report[1] == index && report[2] == feature && report[3] == functionByte;

    public static bool IsErrorFor(ReadOnlySpan<byte> report, byte index, byte feature, byte functionByte) =>
        report.Length >= 5 && report[1] == index && report[2] == 0xFF && report[3] == feature && report[4] == functionByte;
}

/// <summary>One HID++ report collection with simple request/response matching.</summary>
internal sealed class HidppChannel : IDisposable
{
    private const byte LongReportId = 0x11;
    private static readonly TimeSpan ReplyTimeout = TimeSpan.FromMilliseconds(400);
    // A sleeping LIGHTSPEED keyboard answers its first request after roughly 1.2 s.
    private static readonly TimeSpan WakeTimeout = TimeSpan.FromMilliseconds(2000);
    private static readonly TimeSpan WakeGrace = TimeSpan.FromMilliseconds(150);

    private readonly FileStream _stream;
    private readonly byte _softwareId;
    private readonly CancellationTokenSource _readCancel = new();
    private readonly object _lock = new();
    private readonly SemaphoreSlim _requestGate = new(1, 1);
    private TaskCompletionSource<byte[]>? _pending;
    private Func<byte[], bool>? _matches;
    private Action<byte[]>? _collector;

    private HidppChannel(string path, FileStream stream, int reportLength, byte softwareId)
    {
        Path = path;
        _stream = stream;
        ReportLength = reportLength;
        _softwareId = softwareId;
        _ = Task.Run(ReadLoopAsync);
    }

    public string Path { get; }

    public int ReportLength { get; }

    /// <summary>
    /// Raised for every input report, whatever its report id. Handlers run on the read-loop thread
    /// and must not modify the array.
    /// </summary>
    public event Action<byte[]>? ReportReceived;

    public static HidppChannel? TryOpen(string path, byte softwareId)
    {
        var handle = HidNative.Open(path, HidNative.GenericRead | HidNative.GenericWrite);
        if (handle.IsInvalid) return null;
        if (!HidNative.TryGetReportLength(handle, out var length) || length < 7)
        {
            handle.Dispose();
            return null;
        }
        return new HidppChannel(path, new FileStream(handle, FileAccess.ReadWrite, 1, isAsync: true), length, softwareId);
    }

    public async Task SendAsync(byte index, byte feature, byte function, byte[] parameters, CancellationToken token)
    {
        var data = new byte[ReportLength];
        data[0] = LongReportId;
        data[1] = index;
        data[2] = feature;
        data[3] = (byte)((function << 4) | _softwareId);
        Array.Copy(parameters, 0, data, 4, Math.Min(parameters.Length, data.Length - 4));
        await _stream.WriteAsync(data, token);
    }

    /// <summary>Writes a report as given (for example a short-report register access).</summary>
    public async Task SendRawAsync(byte[] report, CancellationToken token) =>
        await _stream.WriteAsync(report, token);

    /// <summary>
    /// Sends ROOT.getFeature to device slots 1-6 at once and returns the slots that answer.
    /// Waits for sleeping devices to wake, then a short grace period after the last reply.
    /// </summary>
    public async Task<List<byte>> FindOnlineDevicesAsync(ushort feature, CancellationToken token)
    {
        var online = new List<byte>();
        var firstReply = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_lock)
        {
            _collector = report =>
            {
                if (report.Length < 5 || report[1] is < 1 or > 6) return;
                var isReply = report[2] == 0x00 && report[3] == _softwareId;
                var isError = report[2] == 0xFF && report[3] == 0x00 && report[4] == _softwareId;
                if (!isReply && !isError) return;
                if (!online.Contains(report[1])) online.Add(report[1]);
                firstReply.TrySetResult();
            };
        }

        try
        {
            for (byte index = 1; index <= 6; index++)
            {
                await SendAsync(index, 0x00, 0, [(byte)(feature >> 8), (byte)feature], token);
            }
            await Task.WhenAny(firstReply.Task, Task.Delay(WakeTimeout, token));
            if (firstReply.Task.IsCompleted) await Task.Delay(WakeGrace, token);
        }
        catch (IOException)
        {
            // Receiver unplugged.
        }
        finally
        {
            lock (_lock) { _collector = null; }
        }

        lock (_lock) { return online.OrderBy(x => x).ToList(); }
    }

    /// <summary>Sends a request and returns the reply parameters, or null on timeout/HID++ error.</summary>
    public async Task<byte[]?> RequestAsync(byte index, byte feature, byte function, byte[] parameters, CancellationToken token)
    {
        await _requestGate.WaitAsync(token);
        var functionByte = (byte)((function << 4) | _softwareId);
        var completion = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            lock (_lock)
            {
                _pending = completion;
                _matches = report => HidppMatch.IsReplyTo(report, index, feature, functionByte) ||
                                     HidppMatch.IsErrorFor(report, index, feature, functionByte);
            }

            await SendAsync(index, feature, function, parameters, token);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(ReplyTimeout);
            var report = await completion.Task.WaitAsync(timeout.Token);
            return report[2] == 0xFF ? null : report[4..];
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
        finally
        {
            lock (_lock) { _pending = null; _matches = null; }
            _requestGate.Release();
        }
    }

    /// <summary>Invokes each handler in isolation so one throwing subscriber cannot stop the others or the read loop.</summary>
    internal static void Dispatch(Action<byte[]>? handlers, byte[] report)
    {
        if (handlers is null) return;
        foreach (var handler in handlers.GetInvocationList().Cast<Action<byte[]>>())
        {
            try { handler(report); }
            catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"HID++ report handler failed: {ex}"); }
        }
    }

    private async Task ReadLoopAsync()
    {
        var buffer = new byte[ReportLength];
        try
        {
            while (!_readCancel.IsCancellationRequested)
            {
                var read = await _stream.ReadAsync(buffer, _readCancel.Token);
                if (read <= 0) break;
                var report = buffer[..read];
                lock (_lock)
                {
                    _collector?.Invoke(report);
                    if (_matches?.Invoke(report) == true) _pending?.TrySetResult(report);
                }
                Dispatch(ReportReceived, report);
            }
        }
        catch
        {
            // Closed or device removed.
        }
    }

    public void Dispose()
    {
        _readCancel.Cancel();
        _stream.Dispose();
        _readCancel.Dispose();
    }
}
