import AppKit
import Foundation
import SystemExtensions

final class CameraExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    enum State: Equatable {
        case notInstalled, activating, needsApproval, installed, needsRestart, failed
    }

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var status = "Camera extension is not installed."

    /// Called on the main queue when macOS waits for the user to allow the extension.
    var onNeedsApproval: (() -> Void)?

    func activate() {
        guard state != .activating else { return }
        setState(.activating, "Requesting camera extension install…")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "com.inputbridge.mac.camera",
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Opens the System Settings page where the camera extension is switched on.
    func openApprovalSettings() {
        let address = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
            ? "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            : "x-apple.systempreferences:com.apple.preference.security?General"
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Where the approval switch is on this macOS version.
    var approvalLocation: String {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
            ? "General → Login Items & Extensions → Camera Extensions"
            : "Privacy & Security, next to “System software from InputBridge was blocked”"
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        setState(.needsApproval, "Allow InputBridge Camera in System Settings → \(approvalLocation).")
        onNeedsApproval?()
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            setState(.installed, "InputBridge Camera is installed. Select it once in Zoom or Meet.")
        case .willCompleteAfterReboot:
            setState(.needsRestart, "Restart the Mac to finish installing InputBridge Camera.")
        @unknown default:
            setState(.failed, "Camera extension result: \(result.rawValue).")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let code = (error as NSError).domain == OSSystemExtensionErrorDomain
            ? OSSystemExtensionError.Code(rawValue: (error as NSError).code)
            : nil
        switch code {
        case .unsupportedParentBundleLocation:
            setState(.failed, "Move InputBridge into the Applications folder, then open it again to install the camera.")
        case .requestCanceled, .requestSuperseded:
            setState(.notInstalled, "Camera extension is not installed.")
        case .codeSignatureInvalid, .validationFailed, .forbiddenBySystemPolicy, .missingEntitlement:
            setState(.failed, "Camera extension: \(error.localizedDescription) This needs a Developer ID signed and notarized build.")
        default:
            setState(.failed, "Camera extension: \(error.localizedDescription)")
        }
    }

    private func setState(_ state: State, _ status: String) {
        self.state = state
        self.status = status
    }
}
