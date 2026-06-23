import Foundation

final class ControllerClient {
    private let session = URLSession(configuration: .default)
    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore.shared
    private let tokenAccount = "paired-controller-token"
    private let controllerKey = "paired-controller"

    var storedController: StoredController? {
        guard let data = defaults.data(forKey: controllerKey) else { return nil }
        return try? JSONDecoder().decode(StoredController.self, from: data)
    }

    var hasToken: Bool { keychain.read(tokenAccount) != nil }
    var lastKnownOffer: ControllerOffer? { storedController?.asOffer() }

    func pair(with offer: ControllerOffer) async throws {
        let clientId = stableClientId()
        var request = URLRequest(url: offer.baseURL.appendingPathComponent("api/pair/request"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairRequest(
            clientId: clientId,
            clientName: Host.current().localizedName ?? "Mac"
        ))

        let (data, response) = try await session.data(for: request)
        try assertHTTP(response)
        let start = try JSONDecoder().decode(PairStartResponse.self, from: data)

        for _ in 0..<90 {
            try await Task.sleep(for: .seconds(1))
            var poll = URLRequest(url: offer.baseURL.appendingPathComponent("api/pair/status/\(start.requestId.uuidString)"))
            poll.setValue(start.secret, forHTTPHeaderField: "X-InputBridge-Pairing-Secret")
            let (statusData, statusResponse) = try await session.data(for: poll)
            try assertHTTP(statusResponse)
            let status = try JSONDecoder().decode(PairStatusResponse.self, from: statusData)

            if status.status == "approved", let token = status.token {
                keychain.write(token, account: tokenAccount)
                save(StoredController(
                    controllerId: offer.controllerId,
                    name: offer.name,
                    host: offer.host,
                    httpPort: offer.httpPort,
                    lastSeen: Date()
                ))
                return
            }
            if status.status == "rejected" { throw ClientError.pairingRejected }
        }
        throw ClientError.pairingTimedOut
    }

    func probe(host rawHost: String, port: Int) async throws -> ControllerOffer {
        let host = normalizedHost(rawHost)
        guard !host.isEmpty, (1...65535).contains(port) else { throw ClientError.invalidAddress }
        guard let url = URL(string: "http://\(host):\(port)/api/health") else {
            throw ClientError.invalidAddress
        }

        let (data, response) = try await session.data(from: url)
        try assertHTTP(response)
        let health = try JSONDecoder().decode(HealthResponse.self, from: data)
        guard health.ok, health.protocolVersion == 1 else { throw ClientError.incompatibleController }

        return ControllerOffer(
            controllerId: health.controllerId,
            name: health.name,
            host: host,
            httpPort: port,
            lastSeen: Date()
        )
    }

    func remember(_ offer: ControllerOffer) {
        guard var stored = storedController, stored.controllerId == offer.controllerId else { return }
        stored.name = offer.name
        stored.host = offer.host
        stored.httpPort = offer.httpPort
        stored.lastSeen = Date()
        save(stored)
    }

    func forget() {
        keychain.delete(tokenAccount)
        defaults.removeObject(forKey: controllerKey)
    }

    func apply(_ mode: ProfileMode, offer: ControllerOffer) async throws {
        guard let token = keychain.read(tokenAccount) else { throw ClientError.notPaired }
        var request = URLRequest(url: offer.baseURL.appendingPathComponent("api/mode/\(mode.rawValue)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        try assertHTTP(response)
        remember(offer)
    }

    private func save(_ controller: StoredController) {
        guard let data = try? JSONEncoder().encode(controller) else { return }
        defaults.set(data, forKey: controllerKey)
    }

    private func stableClientId() -> UUID {
        let key = "inputbridge-client-id"
        if let raw = defaults.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return id
    }

    private func normalizedHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func assertHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.httpFailure }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.httpFailure }
    }

    private struct HealthResponse: Decodable {
        let ok: Bool
        let protocolVersion: Int
        let controllerId: UUID
        let name: String

        enum CodingKeys: String, CodingKey {
            case ok
            case protocolVersion = "protocol"
            case controllerId
            case name
        }
    }

    enum ClientError: LocalizedError {
        case pairingRejected, pairingTimedOut, notPaired, httpFailure, invalidAddress, incompatibleController

        var errorDescription: String? {
            switch self {
            case .pairingRejected:
                return "Pairing was rejected on Windows."
            case .pairingTimedOut:
                return "Pairing approval timed out."
            case .notPaired:
                return "This Mac is not paired with a Windows controller."
            case .httpFailure:
                return "The Windows controller could not be reached or rejected the request."
            case .invalidAddress:
                return "Enter a valid Windows IP address or hostname and port."
            case .incompatibleController:
                return "That address is not a compatible InputBridge controller."
            }
        }
    }
}
