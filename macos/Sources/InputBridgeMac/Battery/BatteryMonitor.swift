import AppKit
import Combine
import IOBluetooth

/// Reads the batteries of the devices connected to this Mac every 5 minutes and on wake, Bluetooth
/// connect/disconnect and `refresh()`, and publishes what the battery columns of the InputBridge menu bar item show. Nothing is shared with the
/// Windows controller: each machine shows only its own connected devices, and a device that disconnects
/// disappears with the next read.
///
/// Reads are blocking (HID++ and `system_profiler`), so they run one at a time on a serial background queue;
/// `BatteryRefreshGate` gives triggers that arrive while a read is in flight one more cycle afterwards.
/// While the setting is off nothing is read and `visible` stays empty.
@MainActor
final class BatteryMonitor: NSObject, ObservableObject {
    private static let interval: UInt64 = 5 * 60 * 1_000_000_000

    @Published private(set) var visible: [BatteryReading] = []

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            // Readings from before the setting was turned off may be stale by the time it is turned on again.
            if !enabled { local = [] }
            publish()
            if enabled { refresh() }
        }
    }

    private let sources: [BatterySource]
    private let queue = DispatchQueue(label: "com.inputbridge.mac.battery", qos: .utility)

    private var local: [BatteryReading] = []
    private var gate = BatteryRefreshGate()
    private var loop: Task<Void, Never>?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    init(sources: [BatterySource], enabled: Bool) {
        self.sources = sources
        self.enabled = enabled
        super.init()
    }

    deinit {
        loop?.cancel()
        connectNotification?.unregister()
        disconnectNotifications.values.forEach { $0.unregister() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func start() {
        guard loop == nil else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        // Also called back for devices that are already connected.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(bluetoothConnected(_:device:)))
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: Self.interval)
            }
        }
    }

    /// Reads all sources now, or right after the cycle in flight.
    func refresh() {
        guard gate.request() else { return }
        startCycle()
    }

    /// Refreshes after `delay` (e.g. while a device that just connected finishes coming up). Every call gets its own
    /// deadline; reads that would overlap are coalesced by the gate.
    func refresh(after delay: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.refresh()
        }
    }

    private func startCycle() {
        let sources = BatteryOrder.sourcesToRead(all: self.sources, enabled: enabled)
        queue.async {
            let readings = BatteryOrder.deduplicated(sources.flatMap { $0.read() })
            Task { @MainActor in self.finishCycle(readings) }
        }
    }

    private func finishCycle(_ readings: [BatteryReading]) {
        // A cycle that started before the setting was turned off must not bring its readings back.
        local = enabled ? readings : []
        publish()
        if gate.finish() { startCycle() }
    }

    private func publish() {
        let shown = enabled ? BatteryOrder.sorted(local) : []
        if shown != visible { visible = shown }
    }

    @objc private func didWake(_ notification: Notification) {
        // Bluetooth devices reconnect a few seconds after wake.
        refresh(after: 10)
    }

    @objc private func bluetoothConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString, disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self, selector: #selector(bluetoothDisconnected(_:device:)))
        }
        // AirPods report their levels a few seconds after the link comes up.
        refresh(after: 5)
    }

    @objc private func bluetoothDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        if let address = device.addressString { disconnectNotifications[address] = nil }
        // A disconnected device is hidden right away.
        refresh(after: 1)
    }
}
