import Foundation
import CoreBluetooth

final class Z407Controller: NSObject, ObservableObject {
    @Published private(set) var status = "Idle"

    private static let peripheralIDKey = "z407-peripheral-id"

    private let serviceUUID = CBUUID(string: "FDC2")
    private let commandUUID = CBUUID(string: "C2E758B9-0E78-41E0-B0CB-98A593193FC5")
    private let responseUUID = CBUUID(string: "B84AC9C6-29C5-46D4-BBA1-9D534784330F")
    private let queue = DispatchQueue(label: "com.inputbridge.z407")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var response: CBCharacteristic?
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingMode: ProfileMode?
    private var timeout: DispatchWorkItem?
    private var settle: DispatchWorkItem?
    private var retrieveFallback: DispatchWorkItem?
    private var phase: Phase = .idle
    private var droppingRetrieve = false
    private var scanning = false

    private enum Phase {
        case idle
        case connecting
        case handshakeInitiate
        case handshakeAck
        case handshakeReady
        case switching
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func switchSource(for mode: ProfileMode) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: Z407Error.connectionFailed)
                    return
                }
                self.beginSwitch(mode: mode, continuation: continuation)
            }
        }
    }

    private func beginSwitch(mode: ProfileMode, continuation: CheckedContinuation<Void, Error>) {
        if self.continuation != nil || phase != .idle {
            continuation.resume(throwing: Z407Error.connectionFailed)
            return
        }

        pendingMode = mode
        self.continuation = continuation
        startTimeout()

        if let peripheral, peripheral.state == .connected, let command {
            writeSource(mode, using: peripheral, characteristic: command)
            succeedKeepSession()
            return
        }

        phase = .connecting
        droppingRetrieve = false
        updateStatus("Searching for Z407…")

        if let peripheral, peripheral.state == .connected {
            peripheral.delegate = self
            peripheral.discoverServices([serviceUUID])
            return
        }

        connectToSpeaker()
    }

    private func connectToSpeaker() {
        beginScan()

        if let match = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
            attachAndConnect(match)
        } else if let storedID, let match = central.retrievePeripherals(withIdentifiers: [storedID]).first {
            attachAndConnect(match)
        }

        scheduleRetrieveFallback()
    }

    private func attachAndConnect(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        storedID = peripheral.identifier
        updateStatus("Connecting to Z407…")

        switch peripheral.state {
        case .connected:
            retrieveFallback?.cancel()
            retrieveFallback = nil
            central.stopScan()
            scanning = false
            peripheral.discoverServices([serviceUUID])
        case .connecting:
            break
        default:
            central.connect(peripheral, options: nil)
        }
    }

    private func beginScan() {
        scanning = true
        central.stopScan()
        central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    private func scheduleRetrieveFallback() {
        retrieveFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .connecting, self.continuation != nil else { return }
            guard self.peripheral?.state != .connected else { return }
            self.dropRetrieveAndKeepScanning()
        }
        retrieveFallback = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func dropRetrieveAndKeepScanning() {
        retrieveFallback = nil
        if let peripheral, peripheral.state != .connected {
            droppingRetrieve = true
            central.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            command = nil
            response = nil
        }
        updateStatus("Searching for Z407…")
        if !scanning { beginScan() }
    }

    private func startHandshake() {
        guard phase == .connecting, let peripheral, let response else { return }
        retrieveFallback?.cancel()
        retrieveFallback = nil
        if response.isNotifying {
            sendHandshakeInitiate()
            return
        }
        peripheral.setNotifyValue(true, for: response)
        scheduleHandshakeCommandFallback()
    }

    private func sendHandshakeInitiate() {
        guard phase == .connecting, let peripheral, let command else { return }
        phase = .handshakeInitiate
        peripheral.writeValue(Data([0x84, 0x05]), for: command, type: .withoutResponse)
        scheduleHandshakeCommandFallback()
    }

    private func writeSource(_ mode: ProfileMode, using peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let commandData = mode == .mac ? Data([0x81, 0x01]) : Data([0x81, 0x02])
        peripheral.writeValue(commandData, for: characteristic, type: .withoutResponse)
        updateStatus(mode == .mac ? "Z407 source: Bluetooth" : "Z407 source: AUX")
    }

    private func sendSourceCommand() {
        settle?.cancel()
        guard phase == .connecting || phase == .handshakeInitiate || phase == .handshakeAck || phase == .handshakeReady,
              let peripheral, let command, let mode = pendingMode else { return }
        phase = .switching
        writeSource(mode, using: peripheral, characteristic: command)
        startSettleTimeout()
    }

    private func handleResponse(_ data: Data) {
        if data == Data([0xD4, 0x05, 0x01]) {
            if let peripheral, let command {
                if phase == .handshakeInitiate { phase = .handshakeAck }
                peripheral.writeValue(Data([0x84, 0x00]), for: command, type: .withoutResponse)
            }
            return
        }

        if data == Data([0xD4, 0x00, 0x01]) {
            guard phase == .handshakeAck || phase == .handshakeInitiate else { return }
            phase = .handshakeReady
            scheduleHandshakeCommandFallback()
            return
        }

        if data == Data([0xD4, 0x00, 0x03]) {
            guard phase == .handshakeReady || phase == .handshakeAck || phase == .handshakeInitiate else { return }
            phase = .handshakeReady
            sendSourceCommand()
            return
        }

        guard let mode = pendingMode else { return }
        let sourceAck = mode == .mac ? Data([0xC1, 0x01]) : Data([0xC1, 0x02])
        let sourceComplete = mode == .mac ? Data([0xCF, 0x04]) : Data([0xCF, 0x05])
        if data == sourceAck || data == sourceComplete {
            succeedKeepSession()
        }
    }

    private func succeedKeepSession() {
        timeout?.cancel()
        timeout = nil
        settle?.cancel()
        settle = nil
        retrieveFallback?.cancel()
        retrieveFallback = nil
        droppingRetrieve = false
        scanning = false
        central.stopScan()
        phase = .idle
        pendingMode = nil
        continuation?.resume()
        continuation = nil
    }

    private func fail(_ error: Error) {
        timeout?.cancel()
        timeout = nil
        settle?.cancel()
        settle = nil
        retrieveFallback?.cancel()
        retrieveFallback = nil
        central.stopScan()
        scanning = false
        droppingRetrieve = false
        phase = .idle
        pendingMode = nil
        updateStatus("Z407 error: \(error.localizedDescription)")

        let pending = continuation
        continuation = nil
        disconnectCurrentPeripheral()
        pending?.resume(throwing: error)
    }

    private func disconnectCurrentPeripheral() {
        central.stopScan()
        scanning = false
        guard let peripheral else {
            command = nil
            response = nil
            return
        }

        if let response, peripheral.state == .connected {
            peripheral.setNotifyValue(false, for: response)
        }
        command = nil
        response = nil
        if peripheral.state == .connected || peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)
        }
        self.peripheral = nil
    }

    private func startTimeout() {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fail(Z407Error.timedOut) }
        timeout = work
        queue.asyncAfter(deadline: .now() + 15, execute: work)
    }

    private func startSettleTimeout() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.succeedKeepSession() }
        settle = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func scheduleHandshakeCommandFallback() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendSourceCommand() }
        settle = work
        queue.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func updateStatus(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.status = value }
    }

    private var storedID: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.peripheralIDKey) else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: Self.peripheralIDKey)
            }
        }
    }
}

extension Z407Controller: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if phase == .connecting, pendingMode != nil, peripheral == nil {
                connectToSpeaker()
            }
            return
        }
        if central.state != .unknown && central.state != .resetting && continuation != nil {
            fail(Z407Error.bluetoothUnavailable)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .connecting else { return }
        if let current = self.peripheral, current.state == .connected || current === peripheral { return }
        if let current = self.peripheral, current.state != .connected {
            droppingRetrieve = true
            central.cancelPeripheralConnection(current)
        }
        central.stopScan()
        scanning = false
        retrieveFallback?.cancel()
        retrieveFallback = nil
        attachAndConnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        droppingRetrieve = false
        storedID = peripheral.identifier
        retrieveFallback?.cancel()
        retrieveFallback = nil
        central.stopScan()
        scanning = false
        updateStatus("Discovering Z407 controls…")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral || self.peripheral == nil else { return }
        self.peripheral = nil
        command = nil
        response = nil
        if phase == .connecting, continuation != nil {
            updateStatus("Searching for Z407…")
            if !scanning { beginScan() }
            return
        }
        fail(error ?? Z407Error.connectionFailed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let wasCurrent = self.peripheral == nil || self.peripheral === peripheral
        guard wasCurrent else { return }

        if droppingRetrieve {
            droppingRetrieve = false
            if self.peripheral === peripheral {
                self.peripheral = nil
                command = nil
                response = nil
            }
            if phase == .connecting, continuation != nil, self.peripheral == nil, !scanning {
                beginScan()
            }
            return
        }

        self.peripheral = nil
        command = nil
        response = nil

        if continuation != nil {
            fail(error ?? Z407Error.connectionFailed)
        }
    }
}

extension Z407Controller: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, phase == .connecting else { return }
        if let error { fail(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            fail(Z407Error.serviceNotFound)
            return
        }
        peripheral.discoverCharacteristics([commandUUID, responseUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, phase == .connecting else { return }
        if let error { fail(error); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == commandUUID { command = characteristic }
            if characteristic.uuid == responseUUID { response = characteristic }
        }
        guard command != nil, response != nil else {
            fail(Z407Error.characteristicNotFound)
            return
        }
        startHandshake()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, phase == .connecting else { return }
        if let error { fail(error); return }
        guard characteristic.uuid == responseUUID, characteristic.isNotifying else { return }
        sendHandshakeInitiate()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, error == nil, characteristic.uuid == responseUUID, let data = characteristic.value else { return }
        handleResponse(data)
    }
}

enum Z407Error: LocalizedError {
    case bluetoothUnavailable, connectionFailed, serviceNotFound, characteristicNotFound, timedOut

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth is unavailable."
        case .connectionFailed: return "Could not connect to Z407."
        case .serviceNotFound: return "Z407 control service was not found."
        case .characteristicNotFound: return "Z407 input-control characteristics were not found."
        case .timedOut: return "Timed out while looking for Z407."
        }
    }
}
