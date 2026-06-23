import Foundation

enum ProfileMode: String, Codable, CaseIterable {
    case windows
    case mac

    var title: String { self == .windows ? "Windows" : "Mac" }
}

struct ControllerOffer: Identifiable, Codable, Hashable {
    let controllerId: UUID
    let name: String
    var host: String
    let httpPort: Int
    var lastSeen: Date
    var id: UUID { controllerId }

    var baseURL: URL { URL(string: "http://\(host):\(httpPort)")! }
}

struct PairRequest: Codable {
    let clientId: UUID
    let clientName: String
}

struct PairStartResponse: Codable {
    let requestId: UUID
    let secret: String
    let status: String
}

struct PairStatusResponse: Codable {
    let ok: Bool
    let status: String
    let token: String?
    let clientName: String?
}

struct StoredController: Codable {
    let controllerId: UUID
    var name: String
}

struct ControllerProfileResponse: Codable {
    let ok: Bool
    let mode: String
}
