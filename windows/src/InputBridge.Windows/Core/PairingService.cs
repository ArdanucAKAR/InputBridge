using System.Collections.Concurrent;

namespace InputBridge.Windows;

public sealed class PairingService
{
    private readonly AppSettings _settings;
    private readonly SettingsStore _store;
    private readonly ConcurrentDictionary<Guid, PendingPairing> _pending = new();
    public event Action? Changed;

    public PairingService(AppSettings settings, SettingsStore store)
    {
        _settings = settings;
        _store = store;
    }

    public PairingStart CreateRequest(Guid clientId, string clientName)
    {
        Cleanup();
        var item = new PendingPairing
        {
            RequestId = Guid.NewGuid(),
            ClientId = clientId,
            ClientName = string.IsNullOrWhiteSpace(clientName) ? "Unnamed Mac" : clientName.Trim(),
            RequestSecret = TokenUtility.NewToken(),
            RequestedAt = DateTimeOffset.UtcNow,
            Status = "pending"
        };
        _pending[item.RequestId] = item;
        Changed?.Invoke();
        return new PairingStart(item.RequestId, item.RequestSecret, "pending");
    }

    public PairingStatus GetStatus(Guid requestId, string secret)
    {
        Cleanup();
        if (!_pending.TryGetValue(requestId, out var pending) || !TokenUtility.EqualsHash(secret, TokenUtility.Hash(pending.RequestSecret)))
            return new PairingStatus("missing", null, null);
        return new PairingStatus(pending.Status, pending.DeliveryToken, pending.ClientName);
    }

    public IReadOnlyList<PendingPairingView> PendingViews() => _pending.Values
        .OrderByDescending(x => x.RequestedAt)
        .Select(x => new PendingPairingView(x.RequestId, x.ClientName, x.RequestedAt, x.Status))
        .ToList();

    public void Approve(Guid requestId)
    {
        if (!_pending.TryGetValue(requestId, out var item) || item.Status != "pending") return;
        var token = TokenUtility.NewToken();
        _settings.TrustedClients.RemoveAll(x => x.ClientId == item.ClientId);
        _settings.TrustedClients.Add(new TrustedClient
        {
            ClientId = item.ClientId,
            ClientName = item.ClientName,
            TokenHashBase64 = TokenUtility.Hash(token),
            PairedAt = DateTimeOffset.UtcNow
        });
        _store.Save(_settings);
        item.DeliveryToken = token;
        item.Status = "approved";
        Changed?.Invoke();
    }

    public void Reject(Guid requestId)
    {
        if (_pending.TryGetValue(requestId, out var item))
        {
            item.Status = "rejected";
            Changed?.Invoke();
        }
    }

    public bool IsTrusted(string token) => _settings.TrustedClients.Any(x => TokenUtility.EqualsHash(token, x.TokenHashBase64));

    private void Cleanup()
    {
        var threshold = DateTimeOffset.UtcNow.AddMinutes(-10);
        foreach (var item in _pending.Where(x => x.Value.RequestedAt < threshold)) _pending.TryRemove(item.Key, out _);
    }

    private sealed class PendingPairing
    {
        public Guid RequestId { get; init; }
        public Guid ClientId { get; init; }
        public string ClientName { get; init; } = "";
        public string RequestSecret { get; init; } = "";
        public DateTimeOffset RequestedAt { get; init; }
        public string Status { get; set; } = "pending";
        public string? DeliveryToken { get; set; }
    }
}

public sealed record PairingStart(Guid RequestId, string Secret, string Status);
public sealed record PairingStatus(string Status, string? Token, string? ClientName);
