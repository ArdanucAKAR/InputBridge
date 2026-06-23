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
        return discovery.offers.first { $0.controllerId == stored.controllerId }
    }

    func pair(_ offer: ControllerOffer) async {
        await run { [weak self] in
            guard let self else { return }
            status = "Waiting for Windows approval…"
            try await controller.pair(with: offer)
            status = "Paired with \(offer.name)."
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
            if z407Enabled { try await z407.switchSource(for: mode) }
            try await controller.apply(mode, offer: offer)
            currentMode = mode
            status = "\(mode.title) profile applied."
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
        do { try await action() }
        catch { status = error.localizedDescription }
    }

    enum AppError: LocalizedError {
        case controllerNotFound
        var errorDescription: String? {
            "The paired Windows controller is not currently discoverable on this local network."
        }
    }
}
