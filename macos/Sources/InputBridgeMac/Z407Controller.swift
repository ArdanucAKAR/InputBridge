import Foundation
import CoreBluetooth

final class Z407Controller: NSObject, ObservableObject {
    @Published private(set) var status = "Idle"

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

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func switchSource(for mode: ProfileMode) async throws {
        if let peripheral, peripheral.state == .connected, let command {
            write(mode, using: peripheral, characteristic: command)
            return
        }

        pendingMode = mode
        peripheral = nil
        command = nil
        response = nil
        updateStatus("Searching for Z407…")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            let work = DispatchWorkItem { [weak self] in self?.fail(Z407Error.timedOut) }
            timeout = work
            queue.asyncAfter(deadline: .now() + 15, execute: work)
            if central.state == .poweredOn { beginScan() }
        }
    }

    private func beginScan() {
        central.stopScan()
        central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func write(_ mode: ProfileMode, using peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let commandData = mode == .mac ? Data([0x81, 0x01]) : Data([0x81, 0x02])
        peripheral.writeValue(commandData, for: characteristic, type: .withoutResponse)
        updateStatus(mode == .mac ? "Z407 source: Bluetooth" : "Z407 source: AUX")
    }

    private func succeedConnection() {
        guard let peripheral, let command, let response, let mode = pendingMode else { return }
        timeout?.cancel(); timeout = nil
        peripheral.setNotifyValue(true, for: response)
        peripheral.writeValue(Data([0x84, 0x05]), for: command, type: .withoutResponse)
        write(mode, using: peripheral, characteristic: command)
        pendingMode = nil
        continuation?.resume()
        continuation = nil
    }

    private func fail(_ error: Error) {
        timeout?.cancel(); timeout = nil
        central.stopScan()
        updateStatus("Z407 error: \(error.localizedDescription)")
        continuation?.resume(throwing: error)
        continuation = nil
        pendingMode = nil
    }

    private func updateStatus(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.status = value }
    }
}

extension Z407Controller: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, pendingMode != nil { beginScan() }
        else if central.state != .unknown && central.state != .resetting && pendingMode != nil { fail(Z407Error.bluetoothUnavailable) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
        updateStatus("Connecting to Z407…")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        updateStatus("Discovering Z407 controls…")
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(error ?? Z407Error.connectionFailed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        command = nil
        response = nil
        if continuation != nil { fail(error ?? Z407Error.connectionFailed) }
    }
}

extension Z407Controller: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            fail(Z407Error.serviceNotFound)
            return
        }
        peripheral.discoverCharacteristics([commandUUID, responseUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail(error); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == commandUUID { command = characteristic }
            if characteristic.uuid == responseUUID { response = characteristic }
        }
        guard command != nil, response != nil else {
            fail(Z407Error.characteristicNotFound)
            return
        }
        succeedConnection()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == responseUUID, let data = characteristic.value else { return }
        if data == Data([0xD4, 0x05, 0x01]), let command {
            peripheral.writeValue(Data([0x84, 0x00]), for: command, type: .withoutResponse)
        }
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
