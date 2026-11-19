import AppKit
import LocalHubCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowsView: View {
    @Environment(HubController.self) private var hub
    @State private var editing: Editing?
    @State private var deleting: WorkflowTemplate?
    @State private var browsingComfy = false
    @State private var checkingHealth: WorkflowTemplate?

    struct Editing: Identifiable {
        let id = UUID()
        var template: WorkflowTemplate
        let isNew: Bool
    }

    var body: some View {
        List {
            Section {
                ForEach(Capability.workflowCapabilities) { capability in
                    let options = hub.templates.filter { $0.capability == capability }
                    if options.isEmpty {
                        LabeledContent {
                            Text("Not set up · Import a workflow").font(.caption).foregroundStyle(.secondary)
                        } label: {
                            Label(capability.title, systemImage: capability.symbol)
                        }
                    } else {
                    Picker(selection: Binding(
                        get: { hub.settings.defaults[capability.rawValue] ?? "" },
                        set: { hub.setDefault($0.isEmpty ? nil : $0, for: capability) })) {
                        Text(options.count == 1 ? "Only workflow (\(options[0].name))" : "Ask the client to choose").tag("")
                        ForEach(options) { Text($0.name).tag("\($0.integrationID)/\($0.id)") }
                    } label: {
                        Label(capability.title, systemImage: capability.symbol)
                    }
                    }
                }
            } header: {
                Text("Used when a request names no model")
            }
            Section("Workflows") {
                ForEach(hub.templates) { template in
                    HStack(spacing: 12) {
                        Image(systemName: template.capability.symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(template.name).font(.body.weight(.medium))
                                Text("\(template.integrationID)/\(template.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text("\(template.capability.title) · \(template.slots.map(\.kind.title).joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let warning = template.unsupportedModelWarning(device: hub.comfyDevices[template.integrationID]) {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("Check Health…") { checkingHealth = template }
                            Button("Edit…") { editing = Editing(template: template, isNew: false) }
                            Button("Remove…", role: .destructive) { deleting = template }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editing = Editing(template: template, isNew: false) }
                }
                if hub.templates.isEmpty {
                    Text("Import a saved workflow or recent run from ComfyUI, or choose a workflow JSON file to enable a capability.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Workflows")
        .task { await hub.refreshComfyDevices() }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("From ComfyUI…") { browsingComfy = true }
                        .disabled(!hub.integrations.contains { $0.kind == .comfyui })
                    Button("From File…") { importWorkflow() }
                } label: {
                    Label("Import Workflow", systemImage: "square.and.arrow.down")
                }
            }
        }
        .sheet(item: $editing) { TemplateEditor(template: $0.template, isNew: $0.isNew) }
        .sheet(item: $checkingHealth) { WorkflowHealthSheet(template: $0) }
        .sheet(isPresented: $browsingComfy) {
            ComfyImportSheet { json, name in
                browsingComfy = false
                do {
                    editing = Editing(template: try TemplateEditor.draft(from: json, filename: name, integrations: hub.integrations), isNew: true)
                } catch { hub.errorMessage = HubController.describe(error) }
            }
        }
        .confirmationDialog("Remove \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove", role: .destructive) { if let deleting { hub.delete(deleting) } }
        } message: {
            Text("Clients asking for this workflow will get “model not found”.")
        }
    }

    /// Saved (UI) and exported (API) workflow files both work; UI files are converted with ComfyUI's node list.
    private func importWorkflow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a ComfyUI workflow (.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                var json = try String(contentsOf: url, encoding: .utf8)
                if json.contains("\"nodes\""), let comfy = hub.integrations.first(where: { $0.kind == .comfyui }) {
                    var converter = ComfyUIConverter(objectInfo: try await ComfyLibrary(integration: comfy).objectInfo())
                    json = try converter.convert(json)
                }
                editing = Editing(template: try TemplateEditor.draft(from: json, filename: url.deletingPathExtension().lastPathComponent,
                    integrations: hub.integrations), isNew: true)
            } catch {
                hub.errorMessage = HubController.describe(error)
            }
        }
    }
}

extension Capability {
    var symbol: String {
        switch self {
        case .chat: "text.bubble"
        case .imageCreate: "wand.and.stars"
        case .imageEdit: "paintbrush"
        case .audioSpeech: "speaker.wave.2"
        case .audioCreate: "music.note"
        case .audioEdit: "waveform.badge.magnifyingglass"
        case .videoCreate: "film"
        case .videoEdit: "film.stack"
        case .model3DCreate: "cube"
        case .embeddings: "point.3.connected.trianglepath.dotted"
        case .audioTranscribe: "text.bubble.badge.waveform"
        }
    }
}

struct TemplateEditor: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State var template: WorkflowTemplate
    let isNew: Bool
    @State private var error: String?
    @State private var showingHealth = false

    static func draft(from json: String, filename: String, integrations: [ProviderConfiguration]) throws -> WorkflowTemplate {
        let detected = try WorkflowGraph(json: json).detectSlots()
        let slug = filename.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0 += ($1 == "-" && $0.hasSuffix("-")) ? "" : String($1) }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return WorkflowTemplate(id: String(slug.prefix(48)), name: String(filename.prefix(60)),
            integrationID: integrations.first { $0.kind == .comfyui }?.id ?? "",
            capability: detected.capability, workflow: json, slots: detected.slots, outputNode: detected.outputNode)
    }

    private var graph: WorkflowGraph? { try? WorkflowGraph(json: template.workflow) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let warning = template.unsupportedModelWarning(device: hub.comfyDevices[template.integrationID]) {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Section {
                    TextField("Name", text: $template.name)
                    TextField("ID", text: $template.id).disabled(!isNew)
                    Picker("Runs on", selection: $template.integrationID) {
                        ForEach(hub.integrations.filter { $0.kind == .comfyui }) { Text($0.name).tag($0.id) }
                    }
                    Picker("Capability", selection: $template.capability) {
                        ForEach(Capability.workflowCapabilities) { Text($0.title).tag($0) }
                    }
                    Stepper(value: Binding(get: { template.timeoutMinutes ?? template.capability.defaultTimeoutMinutes },
                                           set: { template.timeoutMinutes = $0 }), in: 1...720, step: 5) {
                        LabeledContent("Stop after", value: "\(template.timeoutMinutes ?? template.capability.defaultTimeoutMinutes) min")
                    }
                }
                Section {
                    ForEach(SlotKind.allCases, id: \.self) { kind in slotRow(kind) }
                    Picker("Output", selection: Binding(get: { template.outputNode ?? "" }, set: { template.outputNode = $0.isEmpty ? nil : $0 })) {
                        Text("Every image output").tag("")
                        ForEach(nodes, id: \.id) { Text(nodeLabel($0)).tag($0.id) }
                    }
                } header: {
                    Text("Request values → workflow inputs")
                } footer: {
                    Text("Clients only fill these inputs; the rest of the workflow stays as imported. What a mask means is up to the workflow: LoadImageMask (alpha) repaints transparent pixels, ImageToMask repaints white ones. Video seconds become frames using the frame rate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                    .padding(.horizontal, 20)
            }
            HStack {
                Button("Check Health…", systemImage: "stethoscope") { showingHealth = true }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    if isNew, hub.templates.contains(where: { $0.id == template.id }) {
                        error = "A workflow with the ID “\(template.id)” already exists"
                    } else if let message = hub.save(template) { error = message } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 600, height: 640)
        .sheet(isPresented: $showingHealth) { WorkflowHealthSheet(template: template) }
    }

    private var nodes: [(id: String, classType: String, title: String?)] { graph?.nodeList ?? [] }

    private func nodeLabel(_ node: (id: String, classType: String, title: String?)) -> String {
        "#\(node.id) \(node.title ?? node.classType)"
    }

    @ViewBuilder
    private func slotRow(_ kind: SlotKind) -> some View {
        let current = template.slot(kind)
        HStack {
            Picker(kind.title, selection: Binding(
                get: { current?.node ?? "" },
                set: { node in
                    template.slots.removeAll { $0.kind == kind }
                    guard !node.isEmpty, let graph else { return }
                    let inputs = graph.scalarInputs(of: node)
                    let preferred = ["text", "image", "audio", "file", "video", "seed", "noise_seed", "steps", "denoise", "seconds", "length", "fps", kind.rawValue].first(where: inputs.contains)
                    if let input = preferred ?? inputs.first { template.slots.append(.init(kind: kind, node: node, input: input)) }
                })) {
                Text("Not used").tag("")
                ForEach(nodes, id: \.id) { Text(nodeLabel($0)).tag($0.id) }
            }
            if let current, let graph {
                Picker("", selection: Binding(
                    get: { current.input },
                    set: { input in
                        if let index = template.slots.firstIndex(where: { $0.kind == kind }) { template.slots[index].input = input }
                    })) {
                    ForEach(graph.scalarInputs(of: current.node), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
    }
}
