import AppKit
import SwiftUI

/// The InputBridge settings window. It is created on first use and reused afterwards, so closing it keeps the
/// selected section and its size.
@MainActor
final class SetupWindowController {
    private static let minimumSize = NSSize(width: 780, height: 540)

    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let view = SetupView(model: model, updates: model.updates)
            .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.minimumSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "InputBridge"
        window.contentViewController = NSHostingController(rootView: view)
        window.contentMinSize = Self.minimumSize
        // Setting the content view controller sizes the window to the view; start at the minimum instead.
        window.setContentSize(Self.minimumSize)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        return window
    }
}
