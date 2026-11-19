import AppKit
import LocalHubCore
import SwiftUI

struct MCPServerEditor: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    @State var server: MCPServerConfiguration
    let originalID: String?
    @State private var transport: Transport = .command
    @State private var arguments = ""
    @State private var tools: [(name: String, description: String)] = []
    @State private var discovering = false
    @State private var error: String?
    @State private var saving = false

    enum Transport: String, CaseIterable { case command = "Command", http = "HTTP" }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("ID", text: $server.id, prompt: Text("files")).disabled(originalID != nil)
                    Picker("Runs as", selection: $transport) {
                        ForEach(Transport.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if transport == .command {
                        LabeledContent("Command") {
                            HStack {
                                TextField("", text: Binding(get: { server.executable ?? "" }, set: { server.executable = $0 }),
                                    prompt: Text("/opt/homebrew/bin/npx"))
                                Button("Choose…") { chooseExecutable() }
                            }
                        }
                        TextField("Arguments", text: $arguments, prompt: Text("-y @modelcontextprotocol/server-filesystem /Users/me/Art"))
                        TextField("Working folder", text: Binding(get: { server.workingDirectory ?? "" },
                            set: { server.workingDirectory = $0.isEmpty ? nil : $0 }), prompt: Text("Optional"))
                    } else {
                        TextField("Endpoint", text: Binding(get: { server.endpoint ?? "" }, set: { server.endpoint = $0 }),
                            prompt: Text("http://127.0.0.1:3001/mcp"))
                    }
                } footer: {
                    Text("Commands run as you, on this Mac. Devices can only call the tools you allow below, with arguments checked against each tool's schema.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if tools.isEmpty && server.allowedTools.isEmpty {
                        Text(discovering ? "Starting the server…" : "Discover the server's tools, then allow the ones devices may call.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(toolRows, id: \.name) { tool in
                        Toggle(isOn: Binding(get: { server.allowedTools.contains(tool.name) }, set: { allowed in
                            server.allowedTools.removeAll { $0 == tool.name }
                            if allowed { server.allowedTools.append(tool.name) }
                        })) {
                            Text(tool.name).font(.body.monospaced())
                            if !tool.description.isEmpty { Text(tool.description).lineLimit(2) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Allowed tools")
                        Spacer()
                        if discovering { ProgressView().controlSize(.small) }
                        Button("Discover Tools") { Task { await discover() } }.disabled(discovering)
                    }
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                    .padding(.horizontal, 20)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(originalID == nil ? "Add" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(saving)
            }
            .padding(20)
        }
        .frame(width: 560, height: 600)
        .onAppear {
            transport = server.endpoint != nil ? .http : .command
            arguments = (server.arguments ?? []).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        }
    }

    /// Discovered tools, plus allowed ones the server no longer reports (so they can be switched off).
    private var toolRows: [(name: String, description: String)] {
        tools + server.allowedTools.filter { name in !tools.contains { $0.name == name } }.map { ($0, "Not reported by the server") }
    }

    private var resolved: MCPServerConfiguration {
        var copy = server
        if transport == .command {
            copy.endpoint = nil
            copy.arguments = Self.split(arguments)
        } else {
            copy.executable = nil; copy.arguments = nil; copy.workingDirectory = nil
        }
        return copy
    }

    private func discover() async {
        error = nil
        discovering = true
        defer { discovering = false }
        do { tools = try await MCPRegistry.discover(resolved) }
        catch { self.error = "Could not list tools: \(HubController.describe(error))" }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if let message = await hub.save(resolved, replacing: originalID) { error = message } else { dismiss() }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { server.executable = url.path }
    }

    /// Splits on spaces, keeping "quoted parts" together.
    static func split(_ text: String) -> [String] {
        var parts: [String] = [], current = "", quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            else if character == " " && !quoted { if !current.isEmpty { parts.append(current); current = "" } }
            else { current.append(character) }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
