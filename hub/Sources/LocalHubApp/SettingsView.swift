import AppKit
import LocalHubCore
import SwiftUI

struct SettingsView: View {
    @Environment(HubController.self) private var hub
    @State private var port = ""

    var body: some View {
        Form {
            Section("Network") {
                Toggle(isOn: setting(\HubSettings.lanEnabled)) {
                    Text("Allow devices on this network")
                    Text("Tablets and other computers on your Wi-Fi can connect after pairing. Requests from outside private networks are always refused.")
                }
                LabeledContent("Port") {
                    HStack {
                        TextField("", text: $port).frame(width: 80).multilineTextAlignment(.trailing)
                        Button("Apply") {
                            guard let value = Int(port) else { hub.errorMessage = "Port must be a number"; return }
                            var next = hub.settings
                            next.port = value
                            Task { await hub.apply(next) }
                        }
                        .disabled(port == String(hub.settings.port))
                    }
                }
                Toggle(isOn: setting(\HubSettings.allowVPN)) {
                    Text("Allow VPN addresses (Tailscale)")
                    Text("Also accept devices reaching this Mac over a 100.64.0.0/10 VPN such as Tailscale. Pairing and pinning stay the same.")
                }
                .disabled(!hub.settings.lanEnabled)
                LabeledContent("Address", value: hub.address).textSelection(.enabled)
            }
            Section("Pairing") {
                Toggle(isOn: setting(\HubSettings.askOnFirstUse)) {
                    Text("Ask when a device needs a new permission")
                    Text("Instead of refusing, the request waits up to a minute while you allow or deny it here.")
                }
                Toggle(isOn: setting(\HubSettings.legacyV1)) {
                    Text("ArtBlend Companion compatibility")
                    Text("Serve the v1 routes so ArtBlend builds that only know the Companion QR keep working.")
                }
            }
            Section("Jobs") {
                Toggle("Pause local queue", isOn: setting(\HubSettings.queue.paused))
                Stepper(value: setting(\HubSettings.queue.maxConcurrent), in: 1...16) {
                    LabeledContent("Workflows at once across integrations", value: "\(hub.settings.queue.maxConcurrent)")
                }
                Text("Each ComfyUI integration runs one LocalHub workflow at a time. Waiting devices take turns; running jobs continue when the local queue is paused.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: setting(\HubSettings.queue.nightStartHour), in: 0...23) {
                    LabeledContent("Night queue starts", value: "\(hub.settings.queue.nightStartHour):00")
                }
                Stepper(value: setting(\HubSettings.queue.nightEndHour), in: 0...23) {
                    LabeledContent("Night queue ends", value: "\(hub.settings.queue.nightEndHour):00")
                }
                Text("Night hours follow this Mac's time zone. Equal start and end hours allow the whole day. Sleep delays work until the Mac wakes.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: setting(\HubSettings.minFreeMemoryGB), in: 0...64, step: 1) {
                    LabeledContent("Start workflows only with", value: hub.settings.minFreeMemoryGB == 0
                        ? "no memory check" : "\(Int(hub.settings.minFreeMemoryGB)) GB free")
                }
                Text("Heavy jobs wait in the queue until the Mac has this much free memory, instead of slowing everything down.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: setting(\HubSettings.maxJobsPerDevice), in: 1...16) {
                    LabeledContent("Jobs at once per device", value: "\(hub.settings.maxJobsPerDevice)")
                }
            }
            Section("Chat logs") {
                Stepper(value: setting(\HubSettings.retentionDays), in: 1...365) {
                    LabeledContent("Keep logs for", value: "\(hub.settings.retentionDays) day\(hub.settings.retentionDays == 1 ? "" : "s")")
                }
                Text("Logging can be turned off per device under Devices.").font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open LocalHub at login", isOn: Binding(get: { hub.launchAtLogin }, set: { hub.setLaunchAtLogin($0) }))
            }
            Section("Usage metadata") {
                Stepper(value: setting(\HubSettings.usageRetentionDays), in: 1...3650) {
                    LabeledContent("Keep request counts for", value: "\(hub.settings.usageRetentionDays) days")
                }
                Text("Usage keeps model IDs, device names, timings, status and provider-reported token counts separately from chat content. Deleting chats or disabling chat logging does not remove these statistics. Usage can be cleared from the Usage screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: hubVersion)
                LabeledContent("Hub ID", value: hub.core.identity.id).textSelection(.enabled)
                LabeledContent("Certificate SHA-256") {
                    Text(hub.core.certificate.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Data") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hub.core.directory]) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { port = String(hub.settings.port) }
    }

    private func setting<T>(_ keyPath: WritableKeyPath<HubSettings, T>) -> Binding<T> {
        Binding(get: { hub.settings[keyPath: keyPath] }, set: { value in
            var next = hub.settings
            next[keyPath: keyPath] = value
            Task { await hub.apply(next) }
        })
    }
}

struct MenuBarContent: View {
    @Environment(HubController.self) private var hub
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        ForEach(hub.permissionRequests) { request in
            Divider()
            Text("\(request.deviceName) asks to \(request.title)")
            Button("Allow") { hub.answer(request, allow: true) }
            Button("Deny") { hub.answer(request, allow: false) }
        }
        Divider()
        Button("Open LocalHub") { NSApp.bringToFront(); openWindow(id: "main") }
        Button("Pair a Device…") { NSApp.bringToFront(); openWindow(id: "pair") }
        Divider()
        ForEach(hub.integrations) { integration in
            let status = hub.statuses[integration.id]
            Text("\(status?.state == "running" ? "●" : "○")  \(integration.name) — \(status?.label ?? "…")")
        }
        Divider()
        Button("Quit LocalHub") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private var statusLine: String {
        switch hub.serverState {
        case .running: "LocalHub is running · \(hub.devices.count) device\(hub.devices.count == 1 ? "" : "s")"
        case .starting: "LocalHub is starting…"
        case .stopped: "LocalHub is stopped"
        case .failed(let reason): "LocalHub failed: \(reason)"
        }
    }
}
