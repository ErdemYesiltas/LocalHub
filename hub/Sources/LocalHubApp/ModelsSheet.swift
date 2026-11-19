import LocalHubCore
import SwiftUI

/// LM Studio's models: what is downloaded, what is in memory, load and unload.
struct ModelsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let integration: ProviderConfiguration
    @State private var models: [LMStudioManager.Model] = []
    @State private var busy: String?
    @State private var error: String?
    @State private var unsupported = false

    private var manager: LMStudioManager { LMStudioManager(integration: integration) }

    var body: some View {
        VStack(spacing: 0) {
            List(models) { model in
                HStack(spacing: 10) {
                    Image(systemName: model.type == "embedding" ? "point.3.connected.trianglepath.dotted" : model.type == "vlm" ? "eye" : "text.bubble")
                        .frame(width: 20).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                        Text("\(model.key) · \(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .memory))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if busy == model.key {
                        ProgressView().controlSize(.small)
                    } else if model.loaded {
                        Label("In memory", systemImage: "memorychip").font(.caption).foregroundStyle(.green)
                        Button("Unload") { Task { await run(model.key) { for instance in model.instances { try await manager.unload(instance: instance) } } } }
                    } else {
                        Button("Load") { Task { await run(model.key) { try await manager.load(model.key) } } }
                    }
                }
                .padding(.vertical, 3)
            }
            .overlay {
                if unsupported {
                    ContentUnavailableView("No model management", systemImage: "cpu",
                        description: Text("\(integration.name) does not offer LM Studio's model API. Load models in the app itself."))
                } else if models.isEmpty && error == nil {
                    ProgressView()
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).padding(.horizontal, 16).padding(.top, 8)
            }
            HStack {
                Text("Loading a model uses the Mac's memory until it is unloaded. Requests to an unloaded model load it on first use.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 440)
        .navigationTitle("\(integration.name) Models")
        .task { await reload() }
    }

    private func reload() async {
        do { models = try await manager.catalog(); unsupported = false }
        catch { unsupported = true }
    }

    private func run(_ key: String, _ action: @escaping () async throws -> Void) async {
        busy = key
        error = nil
        defer { busy = nil }
        do { try await action() } catch { self.error = HubController.describe(error) }
        await reload()
    }
}
