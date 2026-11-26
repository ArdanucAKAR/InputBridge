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
    /// The click on the item that closed the transient popover, if one did. That click closes the popover on mouse
    /// down, then reaches the button's action on mouse up; that one action must not reopen it.
    private var closingClick: Int?
    private var cancellables = Set<AnyCancellable>()

    /// Empty space left and right of the content, inside the item's highlight.
    private static let horizontalInset: CGFloat = 3

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
                content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: Self.horizontalInset),
                content.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -Self.horizontalInset),
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
        item.length = content.intrinsicContentSize.width + 2 * Self.horizontalInset

        guard let button = item.button else { return }
        button.toolTip = tooltip.isEmpty ? nil : tooltip
        // The item draws symbols and numbers; VoiceOver reads the device names and levels instead.
        let name = updateAvailable ? "InputBridge, update available" : "InputBridge"
        button.setAccessibilityLabel(tooltip.isEmpty ? name : name + "\n" + tooltip)
    }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        let closedByThisClick = closingClick != nil && closingClick == Self.clickNumber(NSApp.currentEvent)
        closingClick = nil
        if closedByThisClick { return }

        if popover.isShown {
            popover.performClose(sender)
            closingClick = nil // closed by this action, not before it
            return
        }
        guard let button = item.button else { return }
        // An accessory app must be active for the transient popover to close on a click elsewhere.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // After the button's own mouse tracking, which would otherwise clear the highlight again.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.item.button?.highlight(true)
        }
    }

    private func openSettings() {
        popover.performClose(nil)
        settings.show() // activates the app
    }

    func popoverWillClose(_ notification: Notification) {
        // A click on the item itself, as opposed to one elsewhere, Escape or Settings….
        let event = NSApp.currentEvent
        guard let event, let button = item.button, event.window === button.window else { return }
        closingClick = Self.clickNumber(event)
    }

    func popoverDidClose(_ notification: Notification) {
        item.button?.highlight(false)
    }

    /// Identifies a click: a mouse-up carries the event number of its mouse-down. Nil for anything but a click,
    /// where `eventNumber` is not available.
    private static func clickNumber(_ event: NSEvent?) -> Int? {
        guard let event else { return nil }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return event.eventNumber
        default:
            return nil
        }
    }
}
