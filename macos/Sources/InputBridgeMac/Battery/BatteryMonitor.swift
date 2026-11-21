import AppKit
import Combine
import IOBluetooth

/// Reads this Mac's device batteries every 5 minutes and on wake, Bluetooth connect/disconnect and `refresh()`,
/// shares the keyboard reading with the paired Windows controller and publishes what the menu bar strip shows.
/// While the keyboard is not on this Mac, the reading Windows has is fetched every minute (only that cheap request).
/// Before sleep and on quit the Mac tells Windows it no longer holds the keyboard, so Windows hides it at once.
///
/// Reads are blocking (HID++ and `system_profiler`), so they run one at a time on a serial background queue;
/// `BatteryRefreshGate` gives triggers that arrive while a read and its controller exchange are in flight one more
/// cycle afterwards.
/// Turning the setting off only empties `visible`: the keyboard is still read and shared, so the other machine
/// keeps seeing it.
@MainActor
final class BatteryMonitor: NSObject, ObservableObject {
    private static let interval: UInt64 = 5 * 60 * 1_000_000_000
    private static let remoteInterval: UInt64 = 60 * 1_000_000_000
    private static let goodbyeTimeout: TimeInterval = 2

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
    private var gate = BatteryRefreshGate()
    /// Counts the controller answers stored in `remote`, so a slower poll never overwrites a newer cycle's answer.
    private var remoteGeneration = 0
    private var loop: Task<Void, Never>?
    private var remoteLoop: Task<Void, Never>?
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
        remoteLoop?.cancel()
        connectNotification?.unregister()
        disconnectNotifications.values.forEach { $0.unregister() }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard loop == nil else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(willTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
        // Also called back for devices that are already connected.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(bluetoothConnected(_:device:)))
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: Self.interval)
            }
        }
        remoteLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.remoteInterval)
                await self?.pollRemote()
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
        // With the strip off, only the shared keyboard is still needed, and only while a controller is paired.
        let sources = enabled ? [keyboard] + others : (isPaired ? [keyboard] : [])
        queue.async {
            let readings = sources.flatMap { $0.read() }
            Task { @MainActor in await self.finishCycle(readings) }
        }
    }

    private var isPaired: Bool { controller.hasToken && offer() != nil }

    private func finishCycle(_ readings: [BatteryReading]) async {
        local = readings
        publish()
        remote = await exchange(shared: readings.filter { $0.deviceId == BatteryIds.sharedKeyboard })
        remoteGeneration += 1
        publish()
        if gate.finish() { startCycle() }
    }

    /// Posts this Mac's keyboard reading and fetches the one Windows has. A skipped or failed fetch is `[]`, so the
    /// faded keyboard disappears while the link is down. An older controller (404) counts as having none.
    private func exchange(shared: [BatteryReading]) async -> [BatteryReading] {
        guard controller.hasToken, let offer = offer() else { return [] }
        try? await controller.postBattery(shared, offer: offer)
        return (try? await controller.fetchBattery(offer: offer)) ?? []
    }

    /// Between full reads, fetches the keyboard reading Windows has while this Mac has none: no Bluetooth or
    /// `system_profiler` read, only the controller request.
    private func pollRemote() async {
        guard enabled, !gate.running, BatteryMerge.needsRemoteKeyboard(local: local),
              controller.hasToken, let offer = offer() else { return }
        let generation = remoteGeneration
        let fetched = (try? await controller.fetchBattery(offer: offer)) ?? []
        // A cycle that ran meanwhile stored a newer answer, and one still running will store its own.
        guard remoteGeneration == generation, !gate.running else { return }
        remote = fetched
        remoteGeneration += 1
        publish()
    }

    /// Tells Windows this Mac no longer reads the keyboard, so it hides the Mac-held reading now instead of after its
    /// expiry. Best effort: the Mac is about to sleep or quit, so this waits at most `goodbyeTimeout`.
    private func sayGoodbye() {
        guard !BatteryMerge.needsRemoteKeyboard(local: local), controller.hasToken, let offer = offer() else { return }
        let controller = self.controller
        let timeout = Self.goodbyeTimeout
        let sent = DispatchSemaphore(value: 0)
        Task.detached {
            try? await controller.postBattery([], offer: offer, timeout: timeout)
            sent.signal()
        }
        _ = sent.wait(timeout: .now() + timeout)
    }

    private func publish() {
        let shown = enabled ? BatteryMerge.visible(local: local, remote: remote) : []
        if shown != visible { visible = shown }
    }

    @objc private func willSleep(_ notification: Notification) {
        sayGoodbye()
    }

    @objc private func willTerminate(_ notification: Notification) {
        sayGoodbye()
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
