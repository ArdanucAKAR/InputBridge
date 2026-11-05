import SwiftUI
import AppKit

@main
struct InputBridgeMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("InputBridge", systemImage: "arrow.left.arrow.right") {
            MenuBarContent(model: model)
        }

        Window("InputBridge Setup", id: "setup") {
            SetupView(model: model)
                .frame(minWidth: 650, minHeight: 760)
                .padding(20)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("InputBridge").font(.headline)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Automation enabled", isOn: $model.automationEnabled)
                .onChange(of: model.automationEnabled) { value in
                    UserDefaults.standard.set(value, forKey: "automation-enabled")
                }
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Button("Apply Windows profile") { Task { await model.apply(.windows) } }
                .disabled(model.busy)
            Button("Apply Mac profile") { Task { await model.apply(.mac) } }
                .disabled(model.busy)
            Divider()
            UpdateMenuItem(updates: model.updates)
            Button("Open setup…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "setup")
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("InputBridge setup").font(.title2).bold()
            Text(model.status).foregroundStyle(.secondary)

            GroupBox("Windows Controller") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.discovery.offers.isEmpty {
                        Text("Searching the local network…")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.discovery.offers) { offer in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(offer.name).fontWeight(.medium)
                                    Text("\(offer.host):\(offer.httpPort) • found automatically")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.controller.storedController?.controllerId == offer.controllerId && model.controller.hasToken {
                                    Text("Paired").foregroundStyle(.green)
                                } else {
                                    Button("Pair") { Task { await model.pair(offer) } }
                                        .disabled(model.busy)
                                }
                            }
                        }
                    }

                    if model.controller.hasToken {
                        Button("Forget pairing", role: .destructive) { model.forget() }
                    }
                }
                .padding(6)
            }

            GroupBox("Can’t find Windows automatically?") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automatic discovery uses both multicast and local broadcast. This fallback is only for networks that block those packets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Windows IP or hostname", text: $model.manualHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("41715", text: $model.manualPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Button("Check address") { Task { await model.checkManualController() } }
                            .disabled(model.busy)
                    }
                }
                .padding(6)
            }

            GroupBox("Devices") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Keyboard name pattern")
                        TextField("G915|G913", text: $model.keyboardPattern)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("Z407 source switch")
                        Toggle("Enable Logitech Z407 adapter", isOn: $model.z407Enabled)
                    }
                    GridRow {
                        Text("Windows camera share")
                        Toggle("Enable InputBridge Camera", isOn: $model.cameraShareEnabled)
                    }
                }
                Text("Connected keyboard → Mac profile. Disconnected keyboard → Windows profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CameraExtensionStatusView(installer: model.cameraExtension)
                HStack {
                    Button("Save device settings") { model.saveDeviceSettings() }
                    Spacer()
                    Text("Z407: \(model.z407.status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            UpdateSettingsView(updates: model.updates)

            GroupBox("Test profiles") {
                HStack {
                    Button("Test Windows profile") { Task { await model.apply(.windows) } }
                        .disabled(model.busy)
                    Button("Test Mac profile") { Task { await model.apply(.mac) } }
                        .disabled(model.busy)
                    Spacer()
                }
                .padding(4)
            }

            Spacer()
        }
    }
}

private struct UpdateMenuItem: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        if updates.state == .readyToInstall, let release = updates.latest {
            Button("Install update \(release.version) and restart") { updates.install() }
        } else {
            Button(updates.isBusy ? "Checking for updates…" : "Check for updates") {
                Task { await updates.check(userInitiated: true) }
            }
            .disabled(updates.isBusy)
        }
    }
}

private struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        GroupBox("Updates") {
            VStack(alignment: .leading, spacing: 8) {
                Text(updates.isDevelopmentBuild ? "Installed version: development build" : "Installed version: \(updates.currentVersion)")
                    .fontWeight(.medium)
                Text(updates.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Check GitHub for updates automatically (every 6 hours)", isOn: $updates.autoCheck)
                Toggle("Install updates automatically", isOn: $updates.autoInstall)
                HStack {
                    Button("Check now") { Task { await updates.check(userInitiated: true) } }
                        .disabled(updates.isBusy)
                    Button("Install and restart") { updates.install() }
                        .disabled(updates.state != .readyToInstall)
                    if let page = updates.latest?.pageURL {
                        Button("Release notes") { NSWorkspace.shared.open(page) }
                    }
                    Spacer()
                }
            }
            .padding(6)
        }
    }
}

private struct CameraExtensionStatusView: View {
    @ObservedObject var installer: CameraExtensionInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(installer.status)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("After install, choose “InputBridge Camera” once in Zoom, Meet or FaceTime. The camera stays plugged into Windows.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Install camera extension") { installer.activate() }
        }
    }
}
