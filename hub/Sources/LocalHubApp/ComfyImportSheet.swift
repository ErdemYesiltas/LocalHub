import LocalHubCore
import SwiftUI

/// Picks a workflow straight from ComfyUI: one the user saved there (converted from the UI
/// format), or the exact graph of a recent run.
struct ComfyImportSheet: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    let onPick: (_ json: String, _ name: String) -> Void

    enum Source: String, CaseIterable { case saved = "Saved in ComfyUI", runs = "Recent runs" }

    @State private var integrationID = ""
    @State private var source: Source = .saved
    @State private var saved: [String] = []
    @State private var runs: [ComfyRun] = []
    @State private var selection: String?
    @State private var loading = false
    @State private var error: String?

    private var comfyIntegrations: [ProviderConfiguration] { hub.integrations.filter { $0.kind == .comfyui } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if comfyIntegrations.count > 1 {
                    Picker("ComfyUI", selection: $integrationID) {
                        ForEach(comfyIntegrations) { Text($0.name).tag($0.id) }
                    }
                    .frame(width: 180)
                }
            }
            .padding(16)

            List(selection: $selection) {
                switch source {
                case .saved:
                    ForEach(saved, id: \.self) { name in
                        Label(Self.title(of: name), systemImage: Self.symbol(of: name)).tag(name)
                    }
                case .runs:
                    ForEach(runs) { run in
                        HStack {
                            Image(systemName: run.output == "audio" ? "music.note" : run.output == "video" ? "film" : "photo")
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.summary.isEmpty ? "\(run.nodeCount)-node workflow" : run.summary)
                                Text("\(run.nodeCount) nodes · \(run.createdAt?.formatted(.relative(presentation: .named)) ?? "earlier")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(run.id)
                    }
                }
            }
            .overlay {
                if loading { ProgressView() }
                else if source == .saved && saved.isEmpty {
                    ContentUnavailableView("No saved workflows", systemImage: "tray",
                        description: Text("Workflows saved in ComfyUI (Workflow › Save) appear here."))
                } else if source == .runs && runs.isEmpty {
                    ContentUnavailableView("No recent runs", systemImage: "clock",
                        description: Text("Run a workflow once in ComfyUI, then import its exact graph here."))
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            HStack {
                Text(source == .saved ? "Saved workflows are converted the way ComfyUI runs them (subgraphs, bypassed nodes)."
                                      : "A run is imported exactly as ComfyUI executed it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { Task { await importSelection() } }
                    .keyboardShortcut(.defaultAction).disabled(selection == nil || loading)
            }
            .padding(16)
        }
        .frame(width: 560, height: 480)
        .task(id: integrationID) { await load() }
        .onChange(of: source) { selection = nil }
        .onAppear { if integrationID.isEmpty { integrationID = comfyIntegrations.first?.id ?? "" } }
    }

    private var library: ComfyLibrary? {
        comfyIntegrations.first { $0.id == integrationID }.map(ComfyLibrary.init(integration:))
    }

    private func load() async {
        guard let library else { return }
        loading = true
        defer { loading = false }
        do {
            async let names = library.savedWorkflows()
            async let recent = library.recentRuns()
            (saved, runs) = try await (names, recent)
            error = nil
        } catch {
            self.error = HubController.describe(error)
        }
    }

    private func importSelection() async {
        guard let library, let selection else { return }
        loading = true
        defer { loading = false }
        do {
            switch source {
            case .saved:
                onPick(try await library.savedWorkflow(selection), Self.title(of: selection))
            case .runs:
                guard let run = runs.first(where: { $0.id == selection }) else { return }
                onPick(run.workflow, run.summary.isEmpty ? "ComfyUI run" : run.summary)
            }
        } catch {
            self.error = HubController.describe(error)
        }
    }

    static func title(of name: String) -> String {
        ((name as NSString).deletingPathExtension as NSString).lastPathComponent.replacingOccurrences(of: "_", with: " ")
    }

    static func symbol(of name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("audio") || lower.contains("tts") { return "music.note" }
        if lower.contains("video") || lower.contains("wan") { return "film" }
        if lower.hasPrefix("3d") { return "cube" }
        return "photo"
    }
}
