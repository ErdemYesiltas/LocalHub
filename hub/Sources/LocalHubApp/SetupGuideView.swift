import LocalHubCore
import SwiftUI

struct SetupGuideView: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    let navigate: (SidebarItem) -> Void
    @State private var updatingNetwork = false

    private var connected: Bool { !hub.readyCapabilities.isEmpty }
    private var completed: Int {
        [connected, hub.hasCompletedPlaygroundRun, !hub.devices.isEmpty].filter { $0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 32)).foregroundStyle(.tint)
                    .frame(width: 56, height: 56)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your local AI, connected.").font(.title2.weight(.semibold))
                    Text("Connect an app on this Mac, try it, then bring your other devices along.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ProgressView(value: Double(completed), total: 3)
                .accessibilityLabel("Setup: \(completed) of 3 steps complete")
            ScrollView {
                VStack(spacing: 12) {
                    step(number: 1, title: "Connect a local AI app", complete: connected,
                         detail: "Start LM Studio or Ollama with a model, or connect ComfyUI and import a workflow.") {
                        HStack {
                            Button("Manage Integrations") { go(.integrations) }
                            if hub.integrations.contains(where: { $0.kind == .comfyui }) {
                                Button("Add a Workflow") { go(.workflows) }
                            }
                            Spacer()
                            Button("Test Connection", systemImage: "arrow.clockwise") {
                                Task { await hub.refreshStatuses(); await hub.refreshModels() }
                            }.disabled(hub.loadingModels || !hub.isRunning)
                        }
                        if !hub.isRunning {
                            HStack {
                                Label("Start the hub to test your connection.", systemImage: "info.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(hub.serverState == .starting ? "Starting…" : "Start Hub") { Task { await hub.start() } }
                                    .disabled(hub.serverState == .starting)
                            }
                        } else if !connected {
                            Text(hub.loadingModels ? "Checking available models…" : "No usable model or workflow found yet. Check that your local app's server is enabled.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    step(number: 2, title: "Make your first request", complete: hub.hasCompletedPlaygroundRun,
                         detail: "Use an example prompt in Playground. This step completes when a request succeeds.") {
                        Button("Open Playground", systemImage: "play.fill") { go(.playground) }
                            .buttonStyle(.borderedProminent)
                    }
                    step(number: 3, title: "Pair another device", complete: !hub.devices.isEmpty,
                         detail: "Optional for use on this Mac. Enable network access, then scan a QR code in ArtBlend or Olive Studio.") {
                        Toggle("Allow devices on this network", isOn: Binding(get: { hub.settings.lanEnabled }, set: { enabled in
                            updatingNetwork = true
                            var next = hub.settings
                            next.lanEnabled = enabled
                            Task { await hub.apply(next); updatingNetwork = false }
                        }))
                        .toggleStyle(.switch)
                        .disabled(updatingNetwork || hub.serverState == .starting)
                        Button("Pair a Device", systemImage: "qrcode") {
                            dismiss()
                            openWindow(id: "pair")
                        }
                        .disabled(updatingNetwork || !hub.isRunning || !hub.settings.lanEnabled)
                    }
                }
            }
            HStack {
                Text("\(completed) of 3 complete · Reopen from Overview anytime")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(completed == 3 ? "Done" : "Continue Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 660)
        .task {
            await hub.refreshStatuses()
            await hub.refreshModels()
            await hub.refreshComfyDevices()
        }
    }

    private func go(_ destination: SidebarItem) {
        dismiss()
        navigate(destination)
    }

    private func step<Content: View>(number: Int, title: String, complete: Bool, detail: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        HubCard {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(complete ? Color.green.opacity(0.12) : Color.accentColor.opacity(0.1))
                    if complete { Image(systemName: "checkmark").foregroundStyle(.green) }
                    else { Text("\(number)").foregroundStyle(.tint) }
                }
                .font(.callout.weight(.semibold)).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    content()
                }
            }
        }
    }
}
