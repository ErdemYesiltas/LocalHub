import AppKit
import LocalHubCore
import SwiftUI
import UniformTypeIdentifiers

struct RecipeSheet: View {
    @Environment(HubController.self) private var hub
    @Environment(\.dismiss) private var dismiss
    let job: HubJob
    @State private var replaying = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Production Recipe", systemImage: "doc.text.magnifyingglass").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(replaying)
            }
            if let recipe = job.recipe {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HubCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(recipe.template.name).font(.headline)
                                Text("Workflow v\(recipe.workflowVersion.prefix(12)) · \(job.capability.title)")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                                if let name = recipe.workProfileName { Text("Work profile: \(name)").font(.caption).foregroundStyle(.secondary) }
                                Text(recipe.parameters.prompt.isEmpty ? "Image input" : recipe.parameters.prompt).textSelection(.enabled)
                                if let parent = recipe.parentJobID {
                                    Text("Based on \(parent)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            if let seed = recipe.parameters.seed { row("Seed", "\(seed)") }
                            if let steps = recipe.parameters.steps { row("Steps", "\(steps)") }
                            if let width = recipe.parameters.width, let height = recipe.parameters.height { row("Size", "\(width) × \(height)") }
                            if let denoise = recipe.parameters.denoise { row("Denoise", String(format: "%.3g", denoise)) }
                            if let seconds = recipe.parameters.seconds { row("Seconds", String(format: "%.3g", seconds)) }
                            if let frames = recipe.parameters.frames { row("Frames", "\(frames)") }
                            if let fps = recipe.parameters.fps { row("FPS", String(format: "%.3g", fps)) }
                            if let negative = recipe.parameters.negativePrompt, !negative.isEmpty { row("Negative prompt", negative) }
                        }.textSelection(.enabled)
                        if !recipe.modelFiles.isEmpty {
                            Text("Model files").font(.headline)
                            ForEach(recipe.modelFiles, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                        }
                        if !recipe.inputs.isEmpty {
                            Text("Retained inputs").font(.headline)
                            ForEach(recipe.inputs) { input in
                                HStack {
                                    Label(input.kind.title, systemImage: "doc")
                                    Spacer()
                                    Text(input.filename).foregroundStyle(.secondary).lineLimit(1)
                                    if (try? hub.core.files.get(input.fileID, deviceID: job.deviceID)).map({ FileManager.default.fileExists(atPath: hub.core.files.contentURL($0).path) }) != true {
                                        Label("Missing", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                    }
                                }.font(.caption)
                            }
                        }
                        Text("Replay uses the saved workflow and inputs. Model files must still be installed. Changes to model binaries or the runtime can change the result even with the same seed.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !hub.isRunning {
                            Button("Start Hub to Replay") { Task { await hub.start() } }.disabled(hub.serverState == .starting)
                        }
                        if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                    }
                }
                HStack {
                    Button("Export Recipe…") { export(recipe) }.disabled(replaying)
                    Spacer()
                    if replaying { ProgressView().controlSize(.small) }
                    Button("Create Variation") { replay(variation: true) }
                        .disabled(replaying || !hub.isRunning || !job.status.isFinished || recipe.parameters.seed == nil)
                    Button("Replay Original") { replay(variation: false) }.buttonStyle(.borderedProminent)
                        .disabled(replaying || !hub.isRunning || !job.status.isFinished)
                }
            } else { ContentUnavailableView("No recipe saved", systemImage: "doc", description: Text("Older jobs do not include a production recipe.")) }
        }
        .padding(24).frame(width: 620, height: 620)
        .interactiveDismissDisabled(replaying)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value) }.font(.callout)
    }

    private func replay(variation: Bool) {
        replaying = true; error = nil
        Task {
            defer { replaying = false }
            do { _ = try await hub.replay(job, variation: variation); dismiss() }
            catch { self.error = HubController.describe(error) }
        }
    }

    private func export(_ recipe: JobRecipe) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(job.id)-recipe.json"
        panel.message = "Includes the workflow and parameters. Input file references are local to this hub; model binaries are not included."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recipe).write(to: destination, options: .atomic)
        } catch { self.error = HubController.describe(error) }
    }
}
