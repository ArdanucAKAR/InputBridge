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

    func pair(with offer: ControllerOffer) async throws {
        let clientId = stableClientId()
        var request = URLRequest(url: offer.baseURL.appendingPathComponent("api/pair/request"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(PairRequest(clientId: clientId, clientName: Host.current().localizedName ?? "Mac"))
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
                let saved = StoredController(controllerId: offer.controllerId, name: offer.name)
                defaults.set(try JSONEncoder().encode(saved), forKey: controllerKey)
                return
            }
            if status.status == "rejected" { throw ClientError.pairingRejected }
        }
        throw ClientError.pairingTimedOut
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
    }

    private func stableClientId() -> UUID {
        let key = "inputbridge-client-id"
        if let raw = defaults.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: key); return id
    }

    private func assertHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ClientError.httpFailure }
    }

    enum ClientError: LocalizedError {
        case pairingRejected, pairingTimedOut, notPaired, httpFailure
        var errorDescription: String? {
            switch self {
            case .pairingRejected: return "Pairing was rejected on Windows."
            case .pairingTimedOut: return "Pairing approval timed out."
            case .notPaired: return "This Mac is not paired with a Windows controller."
            case .httpFailure: return "The Windows controller rejected the request."
            }
        }
    }
}
