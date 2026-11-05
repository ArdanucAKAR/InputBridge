import Combine
import Foundation
import SwiftUI
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published var status = "Discovering Windows controllers…"
    @Published var automationEnabled = UserDefaults.standard.object(forKey: "automation-enabled") as? Bool ?? true
    @Published var currentMode: ProfileMode = .windows
    @Published var busy = false
    @Published var launchAtLogin = UserDefaults.standard.bool(forKey: "launch-at-login")
    @Published var keyboardPattern = UserDefaults.standard.string(forKey: "keyboard-name-pattern") ?? "G915|G913"
    @Published var z407Enabled = UserDefaults.standard.object(forKey: "z407-enabled") as? Bool ?? true
    @Published var cameraShareEnabled = UserDefaults.standard.object(forKey: "camera-share-enabled") as? Bool ?? true
    @Published var keyboardSwitchEnabled = UserDefaults.standard.object(forKey: "keyboard-switch-enabled") as? Bool ?? true
    @Published var manualHost = UserDefaults.standard.string(forKey: "manual-controller-host") ?? ""
    @Published var manualPort = UserDefaults.standard.string(forKey: "manual-controller-port") ?? "41715"
    /// Mirrors `updates.state` so the menu bar label (driven by this model) can show the update badge.
    @Published private(set) var updateAvailable = false

    let discovery = DiscoveryService()
    let controller = ControllerClient()
    let z407 = Z407Controller()
    let cameraExtension = CameraExtensionInstaller()
    let updates = UpdateManager()
    private let cameraStream = CameraStreamClient()
    private var monitor: G915Monitor?
    /// Last profile applied, so the keyboard's own connect/disconnect after a switch does not re-apply it.
    private var lastApplied: (mode: ProfileMode, at: Date)?
    private var keyboardPoll: Task<Void, Never>?

    init() {
        discovery.start()
        restartKeyboardMonitor()
        cameraExtension.activate()
        updates.$state
            .map { $0 == .readyToInstall }
            .removeDuplicates()
            .assign(to: &$updateAvailable)
        updates.start()
    }

    deinit {
        discovery.stop()
        monitor?.stop()
        cameraStream.stop()
    }

    var selectedOffer: ControllerOffer? {
        guard let stored = controller.storedController else { return nil }
        return discovery.offers.first { $0.controllerId == stored.controllerId } ?? stored.asOffer()
    }

    func pair(_ offer: ControllerOffer) async {
        await run { [weak self] in
            guard let self else { return }
            status = "Waiting for Windows approval…"
            try await controller.pair(with: offer)
            status = "Paired with \(offer.name)."
        }
    }

    func checkManualController() async {
        await run { [weak self] in
            guard let self else { return }
            guard let port = Int(manualPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AppError.invalidManualPort
            }
            status = "Checking Windows controller…"
            let offer = try await controller.probe(host: manualHost, port: port)
            UserDefaults.standard.set(manualHost, forKey: "manual-controller-host")
            UserDefaults.standard.set(String(port), forKey: "manual-controller-port")
            discovery.upsert(offer)
            status = "Found \(offer.name) at \(offer.host):\(offer.httpPort)."
        }
    }

    func forget() {
        cameraStream.stop()
        controller.forget()
        status = "Pairing removed."
    }

    func saveDeviceSettings() {
        let pattern = keyboardPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            status = "Keyboard name pattern cannot be empty."
            return
        }
        guard (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil else {
            status = "Keyboard name pattern is not a valid regular expression."
            return
        }
        UserDefaults.standard.set(pattern, forKey: "keyboard-name-pattern")
        UserDefaults.standard.set(z407Enabled, forKey: "z407-enabled")
        UserDefaults.standard.set(cameraShareEnabled, forKey: "camera-share-enabled")
        UserDefaults.standard.set(keyboardSwitchEnabled, forKey: "keyboard-switch-enabled")
        restartKeyboardMonitor()
        updateKeyboardPolling(keyboardOnMac: currentMode == .mac)
        status = "Device settings saved."
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
            UserDefaults.standard.set(enabled, forKey: "launch-at-login")
        } catch {
            launchAtLogin = false
            status = "Could not change login item: \(error.localizedDescription)"
        }
    }

    func detected(_ mode: ProfileMode) async {
        currentMode = mode
        updateKeyboardPolling(keyboardOnMac: mode == .mac)
        if let last = lastApplied, last.mode == mode, Date().timeIntervalSince(last.at) < 20 {
            return // the keyboard moved because InputBridge just applied this profile
        }
        guard automationEnabled else {
            status = "Automation paused. Detected \(mode.title)."
            return
        }
        await apply(mode)
    }

    func apply(_ mode: ProfileMode) async {
        await run { [weak self] in
            guard let self else { return }
            guard let offer = selectedOffer else { throw AppError.controllerNotFound }
            status = "Applying \(mode.title) profile…"
            var z407Note: String?
            if z407Enabled {
                do {
                    try await z407.switchSource(for: mode)
                } catch {
                    z407Note = error.localizedDescription
                }
            }
            try await controller.apply(mode, offer: offer)
            currentMode = mode
            lastApplied = (mode, Date())
            updateCameraStream(mode, offer: offer)

            // Mac profile: Windows moves the keyboard off its receiver. Windows profile: only this Mac can
            // reach the keyboard while it is on Bluetooth.
            var keyboardNote: String?
            if mode == .windows && keyboardSwitchEnabled {
                keyboardNote = await switchKeyboardToWindows()
            }

            var notes = ["\(mode.title) profile applied."]
            if let z407Note { notes.append("Z407: \(z407Note)") }
            if let keyboardNote { notes.append(keyboardNote) }
            status = notes.joined(separator: " ")
        }
    }

    private func switchKeyboardToWindows() async -> String? {
        let pattern = keyboardPattern
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                    let name = try LogitechBluetoothKeyboard.switchAwayFromBluetooth(namePattern: regex)
                    continuation.resume(returning: name == nil ? nil : "Keyboard switched to LIGHTSPEED.")
                } catch {
                    continuation.resume(returning: "Keyboard: \(error.localizedDescription)")
                }
            }
        }
    }

    /// While the keyboard is on this Mac's Bluetooth, the Windows PC cannot reach it. Poll the controller
    /// so a Windows profile chosen on the PC can still bring the keyboard back.
    private func updateKeyboardPolling(keyboardOnMac: Bool) {
        guard keyboardOnMac, keyboardSwitchEnabled else {
            keyboardPoll?.cancel()
            keyboardPoll = nil
            return
        }
        guard keyboardPoll == nil else { return }
        keyboardPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.pollKeyboardRequest()
            }
        }
    }

    private func pollKeyboardRequest() async {
        guard !busy, controller.hasToken, let offer = selectedOffer else { return }
        guard let target = try? await controller.claimKeyboardRequest(offer: offer), target == .windows else { return }
        await apply(.windows)
    }

    private func restartKeyboardMonitor() {
        monitor?.stop()
        monitor = G915Monitor(pattern: keyboardPattern) { [weak self] mode in
            Task { @MainActor in await self?.detected(mode) }
        }
        monitor?.start()
    }

    private func updateCameraStream(_ mode: ProfileMode, offer: ControllerOffer) {
        if mode == .mac, cameraShareEnabled, let token = controller.pairingToken() {
            cameraStream.start(url: controller.cameraStreamURL(offer: offer), token: token)
        } else {
            cameraStream.stop()
        }
    }

    private func run(_ action: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await action()
        } catch {
            status = error.localizedDescription
        }
    }

    enum AppError: LocalizedError {
        case controllerNotFound, invalidManualPort

        var errorDescription: String? {
            switch self {
            case .controllerNotFound:
                return "No paired Windows controller is available. Open setup to pair or check a known address."
            case .invalidManualPort:
                return "Enter a valid controller port, usually 41715."
            }
        }
    }
}
