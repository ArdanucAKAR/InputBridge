import Foundation

enum InputBridgeCameraDevice {
    /// Fixed so the app can find the device and video apps remember it as the selected camera.
    static let deviceID = UUID(uuidString: "6F0C4E2A-8B1D-4C55-9A4E-2B7D3E1F5A90")!
    static let streamID = UUID(uuidString: "0D3B8F61-5C2E-4A7B-8E19-7A4C6D2B9E13")!
    static let name = "InputBridge Camera"
    /// Custom CoreMediaIO device property ('ibcf') through which the app hands the extension a `CameraStreamConfig`.
    static let configSelector: UInt32 = 0x69626366 // 'ibcf'
    static let configPropertyName = "4cc_ibcf_glob_0000"
}

/// Where the camera extension pulls frames from. The app sets it whenever pairing, the controller address,
/// the active profile or the camera setting changes; the extension connects only while an app streams from it.
struct CameraStreamConfig: Codable, Equatable {
    var enabled: Bool
    var url: String
    var token: String

    static let disabled = CameraStreamConfig(enabled: false, url: "", token: "")

    func encoded() -> String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    static func decode(_ string: String) -> CameraStreamConfig? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CameraStreamConfig.self, from: data)
    }
}

/// Splits the controller's `jpeg-framed-v1` stream (uint32 big-endian length, then JPEG bytes) into frames.
struct JPEGFrameParser {
    private var buffer = Data()

    /// Returns the newest complete frame in `data`, dropping older ones that arrived in the same chunk.
    mutating func append(_ data: Data) -> Data? {
        buffer.append(data)
        var newest: Data?
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = UInt32(buffer[start]) << 24 | UInt32(buffer[start + 1]) << 16
                | UInt32(buffer[start + 2]) << 8 | UInt32(buffer[start + 3])
            if length == 0 || length > 8_000_000 {
                buffer.removeAll(keepingCapacity: true)
                return newest
            }
            let total = 4 + Int(length)
            guard buffer.count >= total else { break }
            newest = buffer.subdata(in: (start + 4)..<(start + total))
            buffer.removeSubrange(start..<(start + total))
        }
        return newest
    }

    mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}
