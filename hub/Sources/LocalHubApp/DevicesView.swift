import LocalHubCore
import SwiftUI

struct DevicesView: View {
    @Environment(HubController.self) private var hub
    @Environment(\.openWindow) private var openWindow
    @State private var removing: PairedDevice?

    var body: some View {
        List {
            ForEach(hub.devices) { device in
                DeviceRow(device: device, onRemove: { removing = device })
            }
        }
        .overlay {
            if hub.devices.isEmpty {
                ContentUnavailableView {
                    Label("No paired devices", systemImage: "ipad.and.iphone")
                } description: {
                    Text("Open ArtBlend or Olive Studio and scan the code shown by Pair a Device.")
                } actions: {
                    Button("Pair a Device") { openWindow(id: "pair") }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            ToolbarItem {
                Button("Pair a Device", systemImage: "qrcode") { openWindow(id: "pair") }
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) { if let removing { Task { await hub.revoke(removing) } } }
        } message: {
            Text("Its token stops working immediately. It can pair again with a new code.")
        }
        .task { await hub.refreshDevices() }
    }
}

struct DeviceRow: View {
    @Environment(HubController.self) private var hub
    let device: PairedDevice
    let onRemove: () -> Void
    @State private var expanded = false
    @State private var limitsExpanded = false

    init(device: PairedDevice, onRemove: @escaping () -> Void, expanded: Bool = false) {
        self.device = device; self.onRemove = onRemove
        _expanded = State(initialValue: expanded); _limitsExpanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(device.profileID.flatMap { id in hub.settings.deviceProfiles.first { $0.id == id }?.name }.map { "Policy: \($0) (snapshot)" } ?? "Custom policy")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Apply Policy…") {
                        ForEach(hub.settings.deviceProfiles) { profile in
                            Button(profile.name) { Task { await hub.applyProfile(profile.id, to: device) } }
                        }
                        Divider()
                        Button("Manage Profiles…") { hub.requestedSection = .profiles }
                    }.fixedSize()
                }
                DisclosureGroup("Limits & defaults", isExpanded: $limitsExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("File quota (MiB)") {
                            TextField("MiB", value: Binding(get: { device.effectiveFileQuota(hub.settings) / 1_048_576 }, set: { value in
                                Task { await hub.setDeviceLimits(device, quotaMiB: value, maxJobs: device.effectiveMaxJobs(hub.settings)) }
                            }), format: .number).frame(width: 90)
                        }
                        Stepper("Concurrent jobs: \(device.effectiveMaxJobs(hub.settings))", value: Binding(get: { device.effectiveMaxJobs(hub.settings) }, set: { value in
                            Task { await hub.setDeviceLimits(device, quotaMiB: device.effectiveFileQuota(hub.settings) / 1_048_576, maxJobs: value, preserveQuota: true) }
                        }), in: 1...16)
                        Picker("Default work profile", selection: Binding(get: { device.workProfileID ?? "" }, set: { id in
                            Task { await hub.setWorkProfile(id.isEmpty ? nil : id, for: device) }
                        })) {
                            Text("Workflow / hub defaults").tag("")
                            ForEach(hub.settings.workProfiles) { Text($0.name).tag($0.id) }
                        }
                        Text("Work profiles are preferences; clients can choose a different published profile. Policy permissions and quotas remain enforced.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Text("Can use").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(hub.availableScopes, id: \.id) { scope in
                    Toggle(scope.name, isOn: Binding(
                        get: { device.allows(scope.id) },
                        set: { enabled in Task { await hub.setScope(scope.id, enabled: enabled, for: device) } }))
                }
                Divider()
                Toggle("Keep chat logs", isOn: Binding(
                    get: { device.logging },
                    set: { enabled in Task { await hub.setLogging(enabled, for: device) } }))
                Text("Request counts and token metadata are kept separately for \(hub.settings.usageRetentionDays) days; prompts and replies are not stored when chat logging is off.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Paired \(device.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(device.id)")
                        .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                    Spacer()
                    Button("Remove Device…", role: .destructive, action: onRemove)
                }
            }
            .padding(.leading, 34)
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: device.symbol).font(.title3).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.body.weight(.medium))
                    Text("\(device.app) · \(device.scopes.count) permission\(device.scopes.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(device.lastSeenText).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
