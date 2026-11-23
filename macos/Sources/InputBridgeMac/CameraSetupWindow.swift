import AppKit
import SwiftUI

/// A small window that appears when macOS is waiting for the user to allow InputBridge Camera.
/// Its button opens the exact System Settings page; it closes itself once the camera is installed.
@MainActor
final class CameraSetupWindowController {
    private var window: NSWindow?

    func show(installer: CameraExtensionInstaller) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = CameraSetupView(installer: installer) { [weak self] in self?.close() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set up InputBridge Camera"
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

private struct CameraSetupView: View {
    @ObservedObject var installer: CameraExtensionInstaller
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: installer.state == .installed ? "checkmark.circle.fill" : "video.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(installer.state == .installed ? Color.green : Color.accentColor)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if installer.state == .needsApproval {
                Text("Turn on **InputBridge Camera** in \(installer.approvalLocation). macOS may ask for your password.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                switch installer.state {
                case .installed:
                    Button("Done", action: dismiss)
                        .keyboardShortcut(.defaultAction)
                case .needsApproval:
                    Button("Later", action: dismiss)
                    Button("Open System Settings") { installer.openApprovalSettings() }
                        .keyboardShortcut(.defaultAction)
                default:
                    Button("Close", action: dismiss)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .onChange(of: installer.state) { state in
            // Leave the success message up briefly, then get out of the way.
            guard state == .installed else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { dismiss() }
        }
    }

    private var title: String {
        switch installer.state {
        case .installed: return "InputBridge Camera is ready"
        case .needsRestart: return "Restart to finish"
        case .failed: return "Camera could not be installed"
        default: return "One step to use the Windows camera"
        }
    }

    private var message: String {
        switch installer.state {
        case .installed:
            return "Choose “InputBridge Camera” once in Zoom, Meet or FaceTime. The Windows camera turns on only while one of them uses it."
        case .needsApproval:
            return "InputBridge adds a virtual camera that shows the USB camera plugged into your Windows PC. macOS asks you to allow it once."
        default:
            return installer.status
        }
    }
}
