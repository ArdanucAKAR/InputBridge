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
    @Published var manualHost = UserDefaults.standard.string(forKey: "manual-controller-host") ?? ""
    @Published var manualPort = UserDefaults.standard.string(forKey: "manual-controller-port") ?? "41715"

    let discovery = DiscoveryService()
    let controller = ControllerClient()
    let z407 = Z407Controller()
    private var monitor: G915Monitor?

    init() {
        discovery.start()
        restartKeyboardMonitor()
    }

    deinit {
        discovery.stop()
        monitor?.stop()
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
        restartKeyboardMonitor()
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
            if let z407Note {
                status = "\(mode.title) profile applied. Z407: \(z407Note)"
            } else {
                status = "\(mode.title) profile applied."
            }
        }
    }

    private func restartKeyboardMonitor() {
        monitor?.stop()
        monitor = G915Monitor(pattern: keyboardPattern) { [weak self] mode in
            Task { @MainActor in await self?.detected(mode) }
        }
        monitor?.start()
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
