# InputBridge Local Protocol v1

## UDP discovery

- Multicast group: `239.255.77.77`
- UDP port: `41716`
- Controller HTTP port: `41715` (configurable)

Mac sends:

```json
{"protocol":1,"type":"discover","nonce":"uuid"}
```

Windows replies unicast to the sender:

```json
{
  "protocol":1,
  "type":"offer",
  "nonce":"same-uuid",
  "controllerId":"uuid",
  "name":"WINDOWS-PC",
  "httpPort":41715
}
```

The client uses the source IP of the UDP offer. The endpoint is not permanently trusted: the controller id is the stable identity, and the IP may be refreshed on every discovery.

## Pairing

1. `POST /api/pair/request`
2. Windows user accepts in the controller UI.
3. Mac polls `GET /api/pair/status/{requestId}` with its one-time pairing secret.
4. The response contains a bearer token, saved only in macOS Keychain. Windows stores only a SHA-256 hash of the token.

## Profile execution

`POST /api/mode/{windows|mac}`

```http
Authorization: Bearer <pairing-token>
Content-Type: application/json
```

The Windows controller applies configured monitor actions. The Mac companion applies local BLE actions before it calls this endpoint.
