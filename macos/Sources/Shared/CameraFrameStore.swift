import Foundation

enum InputBridgeCameraDevice {
    /// Fixed so the app can find the device and video apps remember it as the selected camera.
    static let deviceID = UUID(uuidString: "6F0C4E2A-8B1D-4C55-9A4E-2B7D3E1F5A90")!
    static let streamID = UUID(uuidString: "0D3B8F61-5C2E-4A7B-8E19-7A4C6D2B9E13")!
    static let name = "InputBridge Camera"
}

/// Hands camera frames from the app to the camera extension through files.
///
/// The extension runs as the `_cmiodalassistants` user, so an app group container would resolve to a
/// different directory in each process. Both sides use a fixed directory in /tmp instead: the app (the
/// logged-in user) writes, the sandboxed extension reads it through a temporary-exception entitlement.
enum CameraFrameStore {
    static let directoryPath = "/tmp/com.inputbridge.camera"

    static func directory() -> URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
    }

    static func write(jpeg: Data) throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("frame.jpg")
        let tmp = dir.appendingPathComponent("frame.jpg.tmp")
        try jpeg.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
        let seq = "\(UInt64(Date().timeIntervalSince1970 * 1000))\n"
        try seq.write(to: dir.appendingPathComponent("frame.seq"), atomically: true, encoding: .utf8)
    }

    /// Removes the last frame so the extension shows black instead of a frozen picture.
    static func clear() {
        let dir = directory()
        for name in ["frame.seq", "frame.jpg"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    static func read() -> (seq: String, jpeg: Data)? {
        let dir = directory()
        guard let seq = try? String(contentsOf: dir.appendingPathComponent("frame.seq"), encoding: .utf8),
              let jpeg = try? Data(contentsOf: dir.appendingPathComponent("frame.jpg")),
              !jpeg.isEmpty
        else { return nil }
        return (seq.trimmingCharacters(in: .whitespacesAndNewlines), jpeg)
    }
}
