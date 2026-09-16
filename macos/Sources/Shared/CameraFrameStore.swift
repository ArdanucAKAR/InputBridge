import Foundation

enum CameraFrameStore {
    static let appGroup = "group.com.inputbridge.mac"

    static func directory() -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        let fallback = URL(fileURLWithPath: "/tmp/com.inputbridge.camera", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
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

    static func read() -> (seq: String, jpeg: Data)? {
        let dir = directory()
        guard let seq = try? String(contentsOf: dir.appendingPathComponent("frame.seq"), encoding: .utf8),
              let jpeg = try? Data(contentsOf: dir.appendingPathComponent("frame.jpg")),
              !jpeg.isEmpty
        else { return nil }
        return (seq.trimmingCharacters(in: .whitespacesAndNewlines), jpeg)
    }
}
