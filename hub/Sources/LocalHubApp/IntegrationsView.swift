import LocalHubCore
import SwiftUI

struct IntegrationsView: View {
    @Environment(HubController.self) private var hub
    @State private var editing: Editing?
    @State private var deleting: ProviderConfiguration?
    @State private var managingModels: ProviderConfiguration?
    @State private var editingMCP: EditingMCP?
    @State private var deletingMCP: MCPServerConfiguration?

    struct EditingMCP: Identifiable {
        let id = UUID()
        var server: MCPServerConfiguration
        let originalID: String?
    }

    struct Editing: Identifiable {
        let id = UUID()
        var draft: ProviderConfiguration
        let isNew: Bool
    }

    var body: some View {
        List {
            Section("Apps") {
            ForEach(hub.integrations) { integration in
                HStack(spacing: 12) {
                    Image(systemName: integration.kind.symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(integration.name).font(.body.weight(.medium))
                            Text(integration.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text("\(integration.kind.title) · \(integration.baseURL)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let status = hub.statuses[integration.id]
                    StatusDot(color: status?.color ?? .gray.opacity(0.4))
                    Text(status?.label ?? "Checking…").font(.caption).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    Menu {
                        if integration.kind == .openai { Button("Models…") { managingModels = integration } }
                        Button("Edit…") { editing = Editing(draft: integration, isNew: false) }
                        Button("Remove…", role: .destructive) { deleting = integration }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { editing = Editing(draft: integration, isNew: false) }
            }
            }
            Section {
                ForEach(hub.settings.mcpServers) { server in
                    HStack(spacing: 12) {
                        Image(systemName: "wrench.and.screwdriver").font(.title3).foregroundStyle(.tint).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(server.id).font(.body.weight(.medium))
                                Text("mcp:\(server.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text("\(server.endpoint ?? ([server.executable ?? ""] + (server.arguments ?? [])).joined(separator: " ")) · \(server.allowedTools.count) tool\(server.allowedTools.count == 1 ? "" : "s") allowed")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Menu {
                            Button("Edit…") { editingMCP = EditingMCP(server: server, originalID: server.id) }
                            Button("Remove…", role: .destructive) { deletingMCP = server }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editingMCP = EditingMCP(server: server, originalID: server.id) }
                }
                if hub.settings.mcpServers.isEmpty {
                    Text("No MCP servers. Add one to let paired devices call its tools; each device needs the server's permission under Devices.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("MCP servers")
                    Spacer()
                    Button("Add MCP Server…") { editingMCP = EditingMCP(server: MCPServerConfiguration(id: ""), originalID: nil) }
                        .buttonStyle(.link)
                }
            }
        }
        .overlay {
            if hub.integrations.isEmpty && hub.settings.mcpServers.isEmpty {
                ContentUnavailableView("No integrations", systemImage: "puzzlepiece.extension",
                    description: Text("Add LM Studio, Ollama or ComfyUI running on this Mac."))
            }
        }
        .navigationTitle("Integrations")
        .toolbar {
            ToolbarItem {
                Button("Add Integration", systemImage: "plus") {
                    editing = Editing(draft: ProviderConfiguration(id: "", kind: .openai, name: "", baseURL: "http://127.0.0.1:"), isNew: true)
                }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await hub.refreshStatuses() } }
            }
        }
        .sheet(item: $editing) { IntegrationEditor(draft: $0.draft, isNew: $0.isNew) }
        .sheet(item: $managingModels) { ModelsSheet(integration: $0) }
        .sheet(item: $editingMCP) { MCPServerEditor(server: $0.server, originalID: $0.originalID) }
        .confirmationDialog("Remove MCP server \(deletingMCP?.id ?? "")?", isPresented: Binding(get: { deletingMCP != nil }, set: { if !$0 { deletingMCP = nil } })) {
            Button("Remove", role: .destructive) { if let deletingMCP { hub.delete(deletingMCP) } }
        } message: {
            Text("Devices lose access to its tools. The hub restarts its listener briefly.")
        }
        .confirmationDialog("Remove \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Remove", role: .destructive) { if let deleting { hub.delete(deleting) } }
        } message: {
            Text("Paired devices lose access to it. The app itself is not touched.")
        }
        .task { await hub.refreshStatuses() }
    }
}

struct IntegrationEditor: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State var draft: ProviderConfiguration
    let isNew: Bool
    @State private var error: String?
    @State private var test: ProviderStatus?
    @State private var testing = false

    static let presets: [ProviderConfiguration] = [
        .init(id: "lmstudio", kind: .openai, name: "LM Studio", baseURL: "http://127.0.0.1:1234"),
        .init(id: "ollama", kind: .openai, name: "Ollama", baseURL: "http://127.0.0.1:11434"),
        .init(id: "llamacpp", kind: .openai, name: "llama.cpp", baseURL: "http://127.0.0.1:8080"),
        .init(id: "mlx", kind: .openai, name: "MLX", baseURL: "http://127.0.0.1:8080"),
        .init(id: "comfyui", kind: .comfyui, name: "ComfyUI", baseURL: "http://127.0.0.1:8188"),
        .init(id: "comfy-desktop", kind: .comfyui, name: "Comfy Desktop", baseURL: "http://127.0.0.1:8000"),
        .init(id: "whisper", kind: .whisper, name: "whisper.cpp", baseURL: "http://127.0.0.1:8080"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if isNew {
                    Picker("Start from", selection: Binding<String>(get: { "" }, set: { id in
                        if let preset = Self.presets.first(where: { $0.id == id }) { draft = preset; test = nil }
                    })) {
                        Text("Choose…").tag("")
                        ForEach(Self.presets, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                TextField("Name", text: $draft.name)
                TextField("ID", text: $draft.id)
                    .disabled(!isNew)
                    .help("Used in model ids, e.g. \(draft.id.isEmpty ? "lmstudio" : draft.id)/<model>. Can't be changed later.")
                Picker("Type", selection: $draft.kind) {
                    ForEach(ProviderKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("Address", text: $draft.baseURL, prompt: Text("http://127.0.0.1:1234"))
                LabeledContent("Connection") {
                    HStack {
                        if testing { ProgressView().controlSize(.small) }
                        else if let test { StatusDot(color: test.color); Text(test.state == "running" ? test.label : (test.detail ?? test.label)).font(.caption) }
                        Spacer()
                        Button("Test") { Task { await runTest() } }.disabled(testing)
                    }
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                    .padding(.horizontal, 20)
            }
            HStack {
                Text("Only apps on this Mac can be added; the hub never forwards to other hosts.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    if isNew, hub.integrations.contains(where: { $0.id == draft.id }) {
                        error = "An integration with the ID “\(draft.id)” already exists"
                    } else if let message = hub.save(draft) { error = message } else { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    private func runTest() async {
        do { try draft.validate() } catch { self.error = HubController.describe(error); return }
        error = nil
        testing = true
        test = await ProviderRegistry([draft]).statuses().first
        testing = false
    }
}
