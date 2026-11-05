import SwiftUI
import AppKit

@main
struct InputBridgeMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model, updates: model.updates)
        } label: {
            Image(nsImage: MenuBarImage.make(badged: model.updateAvailable))
                .renderingMode(.original)
                .accessibilityLabel(model.updateAvailable ? "InputBridge, update available" : "InputBridge")
        }
        .menuBarExtraStyle(.window)

        Window("InputBridge", id: "setup") {
            SetupView(model: model, updates: model.updates)
                .frame(minWidth: 780, minHeight: 540)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Menu bar icon

/// The colour app icon at menu bar size, optionally with an orange "!" badge in the lower-right corner.
enum MenuBarImage {
    private static let size = NSSize(width: 18, height: 18)

    static func make(badged: Bool) -> NSImage {
        let base = NSImage(named: "MenuBarIcon") ?? NSApp.applicationIconImage ?? NSImage()
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            guard badged else { return true }

            let diameter: CGFloat = 10
            let badge = NSRect(x: rect.maxX - diameter, y: rect.minY, width: diameter, height: diameter)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: badge.insetBy(dx: -1, dy: -1)).fill()
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: badge).fill()

            NSColor.white.setFill()
            let barWidth: CGFloat = 1.6
            let midX = badge.midX - barWidth / 2
            NSBezierPath(roundedRect: NSRect(x: midX, y: badge.minY + 4.0, width: barWidth, height: 4.2), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(ovalIn: NSRect(x: midX, y: badge.minY + 1.8, width: barWidth, height: barWidth)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Menu bar panel

private struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("InputBridge").font(.headline)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if model.busy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)

            if updates.state == .readyToInstall {
                UpdateBanner(updates: updates, compact: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Active profile")
                HStack(spacing: 8) {
                    ProfileTile(title: "Windows", symbol: "desktopcomputer", active: model.currentMode == .windows) {
                        Task { await model.apply(.windows) }
                    }
                    ProfileTile(title: "Mac", symbol: "laptopcomputer", active: model.currentMode == .mac) {
                        Task { await model.apply(.mac) }
                    }
                }
                .disabled(model.busy)
            }
            .padding(14)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.automationEnabled) {
                    Label("Switch with keyboard", systemImage: "keyboard")
                }
                .onChange(of: model.automationEnabled) { value in
                    UserDefaults.standard.set(value, forKey: "automation-enabled")
                }
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Label("Launch at login", systemImage: "power")
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(14)

            Divider()

            HStack(spacing: 14) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "setup")
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                Button {
                    Task { await updates.check(userInitiated: true) }
                } label: {
                    Label(updates.isBusy ? "Checking…" : "Check for updates", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(updates.isBusy)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 330)
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct ProfileTile: View {
    let title: String
    let symbol: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20, weight: .regular))
                Text(title).font(.callout.weight(active ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfileTileStyle(active: active))
    }
}

private struct ProfileTileStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(0.14) : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08))
            )
    }
}

// MARK: - Shared update banner

struct UpdateBanner: View {
    @ObservedObject var updates: UpdateManager
    var compact = false

    var body: some View {
        if updates.state == .readyToInstall, let release = updates.latest {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(compact ? .title3 : .title2)
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("InputBridge \(release.version) is available")
                        .fontWeight(.semibold)
                    if !compact {
                        Text("Downloaded and verified. InputBridge restarts after installing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button(compact ? "Install" : "Install and restart") { updates.install() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(compact ? .small : .regular)
            }
            .padding(compact ? 10 : 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
        }
    }
}

// MARK: - Settings window

private enum SetupSection: String, CaseIterable, Identifiable {
    case controller, devices, camera, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controller: return "Windows Controller"
        case .devices: return "Devices"
        case .camera: return "Camera"
        case .updates: return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .controller: return "desktopcomputer"
        case .devices: return "keyboard"
        case .camera: return "video"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateManager
    @State private var selection: SetupSection? = .controller

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SetupSection.allCases) { section in
                    HStack {
                        Label(section.title, systemImage: section.symbol)
                        Spacer()
                        if section == .updates && updates.state == .readyToInstall {
                            Circle().fill(Color.orange).frame(width: 8, height: 8)
                        }
                    }
                    .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("InputBridge").font(.headline)
                        Text("Mac Companion").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
        } detail: {
            VStack(spacing: 0) {
                if updates.state == .readyToInstall {
                    UpdateBanner(updates: updates)
                        .padding([.horizontal, .top], 20)
                }
                detail(for: selection ?? .controller)
            }
            .navigationTitle((selection ?? .controller).title)
            .safeAreaInset(edge: .bottom) { StatusBar(model: model) }
        }
    }

    @ViewBuilder
    private func detail(for section: SetupSection) -> some View {
        switch section {
        case .controller:
            ControllerPane(model: model, discovery: model.discovery)
        case .devices:
            DevicesPane(model: model, z407: model.z407)
        case .camera:
            CameraPane(model: model, installer: model.cameraExtension)
        case .updates:
            UpdatesPane(updates: updates)
        }
    }
}

private struct StatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.busy {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(Color.green).frame(width: 7, height: 7)
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text("Active: \(model.currentMode.title)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ControllerPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var discovery: DiscoveryService

    var body: some View {
        Form {
            Section {
                if discovery.offers.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Searching the local network…").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(discovery.offers) { offer in
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(offer.name).fontWeight(.medium)
                                Text("\(offer.host):\(offer.httpPort)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.controller.storedController?.controllerId == offer.controllerId && model.controller.hasToken {
                                Label("Paired", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Color.green)
                            } else {
                                Button("Pair") { Task { await model.pair(offer) } }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(model.busy)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if model.controller.hasToken {
                    Button("Forget pairing", role: .destructive) { model.forget() }
                }
            } header: {
                Text("Discovered controllers")
            } footer: {
                Text("Windows PCs running InputBridge on the same network appear here. Pairing is approved once on Windows.")
            }

            Section {
                TextField("Address", text: $model.manualHost, prompt: Text("Windows IP or hostname"))
                TextField("Port", text: $model.manualPort, prompt: Text("41715"))
                HStack {
                    Spacer()
                    Button("Check address") { Task { await model.checkManualController() } }
                        .disabled(model.busy)
                }
            } header: {
                Text("Manual connection")
            } footer: {
                Text("Only needed on networks that block multicast and broadcast discovery.")
            }

            Section("Test profiles") {
                HStack {
                    Button {
                        Task { await model.apply(.windows) }
                    } label: {
                        Label("Apply Windows profile", systemImage: "desktopcomputer")
                    }
                    Button {
                        Task { await model.apply(.mac) }
                    } label: {
                        Label("Apply Mac profile", systemImage: "laptopcomputer")
                    }
                    Spacer()
                }
                .disabled(model.busy)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DevicesPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var z407: Z407Controller

    var body: some View {
        Form {
            Section {
                TextField("Keyboard name", text: $model.keyboardPattern, prompt: Text("G915|G913"))
            } header: {
                Text("Trigger keyboard")
            } footer: {
                Text("Regular expression matched against Bluetooth device names. Connected to this Mac → Mac profile. Disconnected → Windows profile.")
            }

            Section {
                Toggle("Switch the keyboard with the profile", isOn: $model.keyboardSwitchEnabled)
            } header: {
                Text("Keyboard connection")
            } footer: {
                Text("Mac profile: the Windows PC moves the keyboard to Bluetooth. Windows profile: this Mac sends it back to LIGHTSPEED. macOS may ask to allow InputBridge under Privacy & Security → Input Monitoring.")
            }

            Section {
                Toggle("Switch Logitech Z407 source", isOn: $model.z407Enabled)
                LabeledContent("Speaker status") {
                    Text(z407.status).foregroundStyle(.secondary)
                }
            } header: {
                Text("Speakers")
            } footer: {
                Text("Mac profile selects Bluetooth, Windows profile selects AUX.")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save device settings") { model.saveDeviceSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct CameraPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var installer: CameraExtensionInstaller

    var body: some View {
        Form {
            Section {
                Toggle("Use the Windows camera on this Mac", isOn: $model.cameraShareEnabled)
            } footer: {
                Text("While the Mac profile is active, the USB camera attached to Windows streams to “InputBridge Camera”. The camera stays plugged into Windows.")
            }

            Section {
                LabeledContent("Status") {
                    Text(installer.status)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    Spacer()
                    Button("Install camera extension") { installer.activate() }
                }
            } header: {
                Text("InputBridge Camera")
            } footer: {
                Text("After installing, choose “InputBridge Camera” once in Zoom, Meet or FaceTime. Requires a signed build.")
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save camera setting") { model.saveDeviceSettings() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdatesPane: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(updates.isDevelopmentBuild ? "InputBridge (development build)" : "InputBridge \(updates.currentVersion)")
                            .font(.title3.weight(.semibold))
                        Text(updates.status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button {
                                Task { await updates.check(userInitiated: true) }
                            } label: {
                                Label("Check now", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .disabled(updates.isBusy)
                            Button("Install and restart") { updates.install() }
                                .buttonStyle(.borderedProminent)
                                .disabled(updates.state != .readyToInstall)
                            if let page = updates.latest?.pageURL {
                                Button("Release notes") { NSWorkspace.shared.open(page) }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Toggle("Check for updates automatically", isOn: $updates.autoCheck)
                Toggle("Install updates automatically", isOn: $updates.autoInstall)
                Toggle(isOn: $updates.betaUpdates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Receive beta versions")
                        Text("Also offers pre-releases (for example 0.3.0-beta.1). Betas may be less stable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Preferences")
            } footer: {
                Text("InputBridge checks GitHub Releases every 6 hours and verifies each download against its SHA-256 digest.")
            }
        }
        .formStyle(.grouped)
    }
}
