import Foundation
import IOBluetooth

/// Detects whether the configured Logitech keyboard is connected to this Mac over Bluetooth.
/// IOBluetooth is used first. The `system_profiler` fallback is retained because it is proven
/// to expose the G915 state on systems where the legacy IOBluetooth bridge omits BLE keyboards.
final class G915Monitor {
    private let queue = DispatchQueue(label: "com.inputbridge.keyboard-monitor")
    private var timer: DispatchSourceTimer?
    private var current: ProfileMode?
    private var candidate: ProfileMode?
    private var candidateCount = 0
    private let regex: NSRegularExpression
    private let onChange: (ProfileMode) -> Void

    init(pattern: String = "G915|G913", onChange: @escaping (ProfileMode) -> Void) {
        regex = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            ?? (try! NSRegularExpression(pattern: "G915|G913", options: [.caseInsensitive]))
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.sample() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        let state = detect()
        if current == nil {
            current = state
            DispatchQueue.main.async { [onChange] in onChange(state) }
            return
        }

        guard state != current else {
            candidate = nil
            candidateCount = 0
            return
        }

        if candidate == state { candidateCount += 1 }
        else { candidate = state; candidateCount = 1 }

        guard candidateCount >= 2 else { return }
        current = state
        candidate = nil
        candidateCount = 0
        DispatchQueue.main.async { [onChange] in onChange(state) }
    }

    private func detect() -> ProfileMode {
        if let bluetoothResult = detectWithIOBluetooth() { return bluetoothResult ? .mac : .windows }
        return detectWithSystemProfiler() ? .mac : .windows
    }

    /// Returns nil when the target keyboard cannot be found through IOBluetooth.
    private func detectWithIOBluetooth() -> Bool? {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        for device in devices {
            let name = device.name ?? ""
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard regex.firstMatch(in: name, options: [], range: range) != nil else { continue }
            return device.isConnected()
        }
        return nil
    }

    private func detectWithSystemProfiler() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        task.arguments = ["SPBluetoothDataType"]
        task.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        task.standardOutput = pipe

        do { try task.run() }
        catch { return false }
        task.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var connectedSection = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Connected:" { connectedSection = true; continue }
            if trimmed == "Not Connected:" { connectedSection = false; continue }
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if connectedSection, regex.firstMatch(in: text, options: [], range: range) != nil { return true }
        }
        return false
    }
}
