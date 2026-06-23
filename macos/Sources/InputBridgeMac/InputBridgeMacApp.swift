import SwiftUI
import AppKit

@main
struct InputBridgeMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("InputBridge", systemImage: "arrow.left.arrow.right") {
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
                Button("Open setup…") {
                    NSApp.sendAction(
                        Selector(("showSettingsWindow:")),
                        to: nil,
                        from: nil
                    )
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(12)
            .frame(width: 320)
        }
        Settings {
            SetupView(model: model)
                .frame(minWidth: 650, minHeight: 480)
                .padding(20)
        }
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
                        Text("Searching the local network…").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.discovery.offers) { offer in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(offer.name).fontWeight(.medium)
                                    Text("Found automatically on the local network")
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
                }.padding(6)
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
                }
                Text("Connected keyboard → Mac profile. Disconnected keyboard → Windows profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Save device settings") { model.saveDeviceSettings() }
                    Spacer()
                    Text("Z407: \(model.z407.status)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Test profiles") {
                HStack {
                    Button("Test Windows profile") { Task { await model.apply(.windows) } }
                        .disabled(model.busy)
                    Button("Test Mac profile") { Task { await model.apply(.mac) } }
                        .disabled(model.busy)
                    Spacer()
                }.padding(4)
            }

            Spacer()
        }
    }
}
