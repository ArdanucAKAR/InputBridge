import AppKit
import Combine
import IOBluetooth

/// Reads this Mac's device batteries every 5 minutes and on wake, Bluetooth connect/disconnect and `refresh()`,
/// shares the keyboard reading with the paired Windows controller and publishes what the menu bar strip shows.
///
/// Reads are blocking (HID++ and `system_profiler`), so they run one at a time on a serial background queue; a
/// trigger that arrives while a read and its controller exchange are in flight runs one more cycle afterwards.
/// Turning the setting off only empties `visible`: the keyboard is still read and shared, so the other machine
/// keeps seeing it.
@MainActor
final class BatteryMonitor: NSObject, ObservableObject {
    private static let interval: UInt64 = 5 * 60 * 1_000_000_000

    @Published private(set) var visible: [BatteryReading] = []

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            publish()
            if enabled { refresh() }
        }
    }

    private let keyboard: BatterySource
    private let others: [BatterySource]
    private let controller: ControllerClient
    private let offer: @MainActor () -> ControllerOffer?
    private let queue = DispatchQueue(label: "com.inputbridge.mac.battery", qos: .utility)

    private var local: [BatteryReading] = []
    private var remote: [BatteryReading] = []
    private var cycleRunning = false
    private var cyclePending = false
    private var delayedRefresh: Task<Void, Never>?
    private var loop: Task<Void, Never>?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    init(
        keyboard: BatterySource, others: [BatterySource], controller: ControllerClient,
        offer: @escaping @MainActor () -> ControllerOffer?, enabled: Bool
    ) {
        self.keyboard = keyboard
        self.others = others
        self.controller = controller
        self.offer = offer
        self.enabled = enabled
        super.init()
    }

    deinit {
        loop?.cancel()
        delayedRefresh?.cancel()
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
        guard !cycleRunning else {
            cyclePending = true
            return
        }
        cycleRunning = true
        // With the strip off, only the shared keyboard is still needed, and only while a controller is paired.
        let sources = enabled ? [keyboard] + others : (isPaired ? [keyboard] : [])
        queue.async {
            let readings = sources.flatMap { $0.read() }
            Task { @MainActor in await self.finishCycle(readings) }
        }
    }

    /// Refreshes once after `delay` (e.g. while a device that just connected finishes coming up); further calls
    /// before then are folded into that one.
    func refresh(after delay: TimeInterval) {
        guard delayedRefresh == nil else { return }
        delayedRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.delayedRefresh = nil
            self?.refresh()
        }
    }

    private var isPaired: Bool { controller.hasToken && offer() != nil }

    private func finishCycle(_ readings: [BatteryReading]) async {
        local = readings
        publish()
        remote = await exchange(shared: readings.filter { $0.deviceId == BatteryIds.sharedKeyboard })
        publish()
        cycleRunning = false
        if cyclePending {
            cyclePending = false
            refresh()
        }
    }

    /// Posts this Mac's keyboard reading and fetches the one Windows has. A skipped or failed fetch is `[]`, so the
    /// faded keyboard disappears while the link is down. An older controller (404) counts as having none.
    private func exchange(shared: [BatteryReading]) async -> [BatteryReading] {
        guard controller.hasToken, let offer = offer() else { return [] }
        try? await controller.postBattery(shared, offer: offer)
        return (try? await controller.fetchBattery(offer: offer)) ?? []
    }

    private func publish() {
        let shown = enabled ? BatteryMerge.visible(local: local, remote: remote) : []
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
