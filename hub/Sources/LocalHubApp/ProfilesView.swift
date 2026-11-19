import LocalHubCore
import SwiftUI

struct ProfilesView: View {
    @Environment(HubController.self) private var hub
    @State private var deviceEditor: DeviceEdit?
    @State private var workEditor: WorkEdit?
    @State private var deletingDevice: DeviceProfile?
    @State private var deletingWork: WorkProfile?
    struct DeviceEdit: Identifiable { let id = UUID(); let profile: DeviceProfile; let isNew: Bool }
    struct WorkEdit: Identifiable { let id = UUID(); let profile: WorkProfile; let isNew: Bool }

    var body: some View {
        List {
            Section {
                Picker("Policy for new devices", selection: Binding(get: { hub.settings.defaultDeviceProfileID ?? "" }, set: { id in
                    var next = hub.settings; next.defaultDeviceProfileID = id.isEmpty ? nil : id
                    Task { await hub.apply(next) }
                })) {
                    Text("Existing default permissions").tag("")
                    ForEach(hub.settings.deviceProfiles) { Text($0.name).tag($0.id) }
                }
                ForEach(hub.settings.deviceProfiles) { profile in
                    HStack(spacing: 12) {
                        Image(systemName: "lock.shield").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.headline)
                            Text("\(profile.scopes.count) permissions · \(ByteCountFormatter.string(fromByteCount: Int64(profile.fileQuotaBytes), countStyle: .file)) · \(profile.maxJobs) concurrent jobs")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(profile.logging ? "Chat logging on" : "Chat logging off").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Edit…") { deviceEditor = DeviceEdit(profile: profile, isNew: false) }
                            Button("Duplicate…") { var copy = profile; copy.id += "-copy"; copy.name += " Copy"; deviceEditor = DeviceEdit(profile: copy, isNew: true) }
                            Button("Remove…", role: .destructive) { deletingDevice = profile }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    }.padding(.vertical, 5)
                }
            } header: { Text("Device policies") } footer: {
                Text("Apply policies under Devices. A policy copies permissions, logging and limits; later edits do not silently change paired devices. MCP access is granted only when explicitly selected.")
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                ForEach(hub.settings.workProfiles) { profile in
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.headline)
                            Text(workSummary(profile)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Edit…") { workEditor = WorkEdit(profile: profile, isNew: false) }
                            Button("Duplicate…") { var copy = profile; copy.id += "-copy"; copy.name += " Copy"; workEditor = WorkEdit(profile: copy, isNew: true) }
                            Button("Remove…", role: .destructive) { deletingWork = profile }
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                    }.padding(.vertical, 5)
                }
                if hub.settings.workProfiles.isEmpty { Text("Add a work profile to save model and generation defaults.").foregroundStyle(.secondary) }
            } header: { Text("Work profiles") } footer: {
                Text("Choose a profile in Playground or send its ID in the API's profile field. Explicit request values override the profile; unmapped workflow inputs stay unchanged.").lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Device Policy…") {
                        deviceEditor = DeviceEdit(profile: DeviceProfile(id: "", name: "", scopes: [], logging: false, fileQuotaBytes: 2_147_483_648, maxJobs: 2), isNew: true)
                    }
                    Button("Work Profile…") { workEditor = WorkEdit(profile: WorkProfile(id: "", name: ""), isNew: true) }
                    Divider()
                    Button("Restore Missing Presets") { restorePresets() }
                } label: { Label("Add Profile", systemImage: "plus") }
            }
        }
        .sheet(item: $deviceEditor) { DeviceProfileEditor(profile: $0.profile, isNew: $0.isNew) }
        .sheet(item: $workEditor) { WorkProfileEditor(profile: $0.profile, isNew: $0.isNew) }
        .confirmationDialog("Remove device policy?", isPresented: Binding(get: { deletingDevice != nil }, set: { if !$0 { deletingDevice = nil } })) {
            Button("Remove", role: .destructive) {
                do { if let deletingDevice { try hub.deleteProfile(deletingDevice) } } catch { hub.errorMessage = HubController.describe(error) }
            }
        } message: { Text("Existing devices keep their copied permissions and limits. New pairing uses the default permissions if this was the default policy.") }
        .confirmationDialog("Remove work profile?", isPresented: Binding(get: { deletingWork != nil }, set: { if !$0 { deletingWork = nil } })) {
            Button("Remove", role: .destructive) {
                Task { do { if let deletingWork { try await hub.deleteProfile(deletingWork) } } catch { hub.errorMessage = HubController.describe(error) } }
            }
        } message: { Text("Devices using it will return to hub/workflow defaults. Saved recipes keep the settings used for their original run.") }
    }

    private func workSummary(_ profile: WorkProfile) -> String {
        var parts = ["\(profile.models.count) model defaults"]
        if let steps = profile.steps { parts.append("\(steps) steps") }
        if let width = profile.width, let height = profile.height { parts.append("\(width) × \(height)") }
        if let seconds = profile.seconds { parts.append("\(seconds.formatted()) s") }
        if profile.schedule == .night { parts.append("night hours") }
        return parts.joined(separator: " · ")
    }

    private func restorePresets() {
        do {
            for profile in DeviceProfile.presets where !hub.settings.deviceProfiles.contains(where: { $0.id == profile.id }) { try hub.saveProfile(profile, isNew: true) }
            for profile in WorkProfile.presets where !hub.settings.workProfiles.contains(where: { $0.id == profile.id }) { try hub.saveProfile(profile, isNew: true) }
        } catch { hub.errorMessage = HubController.describe(error) }
    }
}

struct DeviceProfileEditor: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State var profile: DeviceProfile
    let isNew: Bool
    @State private var error: String?
    @State private var quotaMiB: String

    init(profile: DeviceProfile, isNew: Bool) {
        _profile = State(initialValue: profile); self.isNew = isNew
        _quotaMiB = State(initialValue: String(Double(profile.fileQuotaBytes) / 1_048_576))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Device Policy" : "Edit Device Policy").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $profile.name)
                TextField("ID", text: $profile.id).disabled(!isNew)
                Section("Permissions") {
                    ForEach(hub.availableScopes, id: \.id) { scope in
                        Toggle(scope.name, isOn: Binding(get: { profile.scopes.contains(scope.id) }, set: { enabled in
                            profile.scopes.removeAll { $0 == scope.id }; if enabled { profile.scopes.append(scope.id) }
                        }))
                    }
                }
                Toggle("Keep chat logs", isOn: $profile.logging)
                LabeledContent("File quota (MiB)") {
                    TextField("MiB", text: $quotaMiB).frame(width: 100)
                }
                Stepper("Concurrent jobs: \(profile.maxJobs)", value: $profile.maxJobs, in: 1...16)
            }.formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        guard let value = Double(quotaMiB), value.isFinite, (0...1_048_576).contains(value) else { throw ConfigurationError.invalid("Quota must be 0–1048576 MiB") }
                        profile.fileQuotaBytes = Int((value * 1_048_576).rounded())
                        try hub.saveProfile(profile, isNew: isNew); dismiss()
                    } catch { self.error = HubController.describe(error) }
                }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 560, height: 650)
    }
}

struct WorkProfileEditor: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State var profile: WorkProfile
    let isNew: Bool
    @State private var steps: String
    @State private var width: String
    @State private var height: String
    @State private var seconds: String
    @State private var fps: String
    @State private var error: String?

    init(profile: WorkProfile, isNew: Bool) {
        _profile = State(initialValue: profile); self.isNew = isNew
        _steps = State(initialValue: profile.steps.map(String.init) ?? "")
        _width = State(initialValue: profile.width.map(String.init) ?? "")
        _height = State(initialValue: profile.height.map(String.init) ?? "")
        _seconds = State(initialValue: profile.seconds.map { String($0) } ?? "")
        _fps = State(initialValue: profile.fps.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Work Profile" : "Edit Work Profile").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $profile.name)
                TextField("ID", text: $profile.id).disabled(!isNew)
                Section("Models and workflows") {
                    ForEach(Capability.allCases) { capability in
                        HStack {
                            TextField(capability.title, text: Binding(get: { profile.models[capability.rawValue] ?? "" }, set: { value in
                                profile.models[capability.rawValue] = value.isEmpty ? nil : value
                            }), prompt: Text("Hub default"))
                            Menu {
                                Button("Hub Default") { profile.models[capability.rawValue] = nil }
                                ForEach(hub.playgroundModels.filter { $0.capabilities.contains(capability.rawValue) }) { model in
                                    Button(model.id) { profile.models[capability.rawValue] = model.id }
                                }
                            } label: { Image(systemName: "chevron.down.circle") }.menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                }
                Section("Generation defaults — leave blank to preserve workflow settings") {
                    TextField("Steps", text: $steps)
                    HStack { TextField("Width", text: $width); TextField("Height", text: $height) }
                    TextField("Seconds", text: $seconds)
                    TextField("FPS", text: $fps)
                    TextField("Negative prompt", text: Binding(get: { profile.negativePrompt ?? "" }, set: { profile.negativePrompt = $0.isEmpty ? nil : $0 }), axis: .vertical)
                }
                Section("Workflow queue") {
                    Picker("Schedule", selection: Binding(get: { profile.schedule ?? .anytime }, set: { profile.schedule = $0 })) {
                        Text("Any time").tag(JobSchedule.anytime)
                        Text("Night hours").tag(JobSchedule.night)
                    }
                    Stepper("Priority: \(profile.priority ?? 0)", value: Binding(get: { profile.priority ?? 0 }, set: { profile.priority = $0 }), in: -10...10)
                    Text("Applies to media workflows. Night hours are configured in Settings; chat and embeddings run immediately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 620, height: 720)
        .task { await hub.refreshModels() }
    }

    private func save() {
        func integer(_ text: String, _ name: String) throws -> Int? {
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            guard let number = Int(text) else { throw ConfigurationError.invalid("\(name) must be a whole number") }
            return number
        }
        func decimal(_ text: String, _ name: String) throws -> Double? {
            if text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            guard let number = Double(text) else { throw ConfigurationError.invalid("\(name) must be a number") }
            return number
        }
        do {
            profile.steps = try integer(steps, "Steps"); profile.width = try integer(width, "Width"); profile.height = try integer(height, "Height")
            profile.seconds = try decimal(seconds, "Seconds"); profile.fps = try decimal(fps, "FPS")
            try hub.saveProfile(profile, isNew: isNew); dismiss()
        } catch { self.error = HubController.describe(error) }
    }
}
