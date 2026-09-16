import Foundation
import SystemExtensions

final class CameraExtensionInstaller: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Camera extension is not installed."

    func activate() {
        status = "Requesting camera extension install…"
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "com.inputbridge.mac.camera",
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "Allow InputBridge Camera in System Settings → Privacy & Security."
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            status = "InputBridge Camera is installed. Select it once in Zoom or Meet."
        case .willCompleteAfterReboot:
            status = "Restart the Mac to finish installing InputBridge Camera."
        @unknown default:
            status = "Camera extension result: \(result.rawValue)."
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = "Camera extension: \(error.localizedDescription). Signed builds are required."
    }
}
