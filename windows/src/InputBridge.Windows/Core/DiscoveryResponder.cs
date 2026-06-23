using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace InputBridge.Windows;

public sealed class DiscoveryResponder : IAsyncDisposable
{
    private readonly AppSettings _settings;
    private UdpClient? _udp;
    private CancellationTokenSource? _cts;
    private Task? _loop;

    public DiscoveryResponder(AppSettings settings) => _settings = settings;

    public Task StartAsync()
    {
        _cts = new CancellationTokenSource();
        _udp = new UdpClient(AddressFamily.InterNetwork) { ExclusiveAddressUse = false };
        _udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _udp.Client.Bind(new IPEndPoint(IPAddress.Any, _settings.DiscoveryPort));
        _udp.JoinMulticastGroup(IPAddress.Parse(_settings.DiscoveryMulticastGroup));
        _loop = Task.Run(() => RunAsync(_cts.Token));
        return Task.CompletedTask;
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        if (_udp is null) return;
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                var received = await _udp.ReceiveAsync(cancellationToken);
                var request = JsonSerializer.Deserialize<DiscoveryRequest>(received.Buffer);
                if (request?.Protocol != 1 || request.Type != "discover" || string.IsNullOrWhiteSpace(request.Nonce)) continue;
                var offer = new DiscoveryOffer(1, "offer", request.Nonce, _settings.ControllerId, Environment.MachineName, _settings.HttpPort);
                var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(offer));
                await _udp.SendAsync(bytes, received.RemoteEndPoint, cancellationToken);
            }
            catch (OperationCanceledException) { break; }
            catch { /* Discovery must survive malformed LAN traffic. */ }
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_cts is not null) _cts.Cancel();
        if (_loop is not null) await _loop;
        _udp?.Dispose();
        _cts?.Dispose();
    }

    private sealed record DiscoveryRequest(int Protocol, string Type, string Nonce);
    private sealed record DiscoveryOffer(int Protocol, string Type, string Nonce, Guid ControllerId, string Name, int HttpPort);
}
