import AppKit
import Combine
import SwiftUI

/// The single InputBridge menu bar item: the app icon and the battery columns, drawn by `StatusItemView`.
/// A click toggles a popover with the InputBridge panel.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let settings: SetupWindowController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let content = StatusItemView()
    private let popover = NSPopover()
    /// When the popover last began closing. A click on the item closes a transient popover on mouse down, then
    /// reaches the button's action on mouse up; that action must not reopen it.
    private var lastClose: Date?
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, settings: SetupWindowController) {
        self.model = model
        self.settings = settings
        super.init()

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            content.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                content.topAnchor.constraint(equalTo: button.topAnchor),
                content.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
        }

        let panel = MenuBarPanel(model: model, updates: model.updates) { [weak self] in self?.openSettings() }
        let hosting = NSHostingController(rootView: panel)
        // The popover follows the panel's size, for example when the update banner appears.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.delegate = self

        model.$updateAvailable
            .combineLatest(model.$batteryColumns, model.$batteryTooltip)
            .sink { [weak self] updateAvailable, columns, tooltip in
                self?.update(updateAvailable: updateAvailable, columns: columns, tooltip: tooltip)
            }
            .store(in: &cancellables)
    }

    private func update(updateAvailable: Bool, columns: [MenuBarColumn], tooltip: String) {
        content.icon = MenuBarImage.make(badged: updateAvailable)
        content.columns = columns
        item.length = content.intrinsicContentSize.width

        guard let button = item.button else { return }
        button.toolTip = tooltip.isEmpty ? nil : tooltip
        // The item draws symbols and numbers; VoiceOver reads the device names and levels instead.
        let name = updateAvailable ? "InputBridge, update available" : "InputBridge"
        button.setAccessibilityLabel(tooltip.isEmpty ? name : name + "\n" + tooltip)
    }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        if let lastClose, Date().timeIntervalSince(lastClose) < 0.3 {
            return // this click already closed the popover
        }
        guard let button = item.button else { return }
        // An accessory app must be active for the transient popover to close on a click elsewhere.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    private func openSettings() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        settings.show()
    }

    func popoverWillClose(_ notification: Notification) {
        lastClose = Date()
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
    }
}
