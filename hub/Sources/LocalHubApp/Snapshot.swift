import AppKit
import CoreFoundation
import LocalHubCore
import SwiftUI

/// `LocalHubApp --snapshot <dir>` renders every screen with sample data into
/// PNGs, without starting the server. Used to review the UI from a script.
@MainActor
enum Snapshot {
    static func run(into directory: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let state = FileManager.default.temporaryDirectory.appendingPathComponent("localhub-snapshot-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: state) }
            let core = try HubCore(directory: state)
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await core.authority.openWindow(code: "482913")
                _ = try? await core.authority.pair(code: "482913", deviceName: "MatePad 11", app: "artblend",
                    requestedScopes: nil, grantable: Capability.allCases.map(\.rawValue), profile: DeviceProfile.presets[0])
                semaphore.signal()
            }
            semaphore.wait()
            try seedSamples(core)
            let controller = HubController(core: core)
            spin(1.0)
            if CommandLine.arguments.contains("--dark") { appearance = .darkAqua }
            if CommandLine.arguments.contains("--review-snapshots") {
                for section in [SidebarItem.overview, .playground, .workflows, .profiles, .usage, .jobs, .diagnostics] {
                    try render(RootView(selection: section).environment(controller), size: CGSize(width: 980, height: 760),
                        to: directory.appendingPathComponent("\(section.rawValue).png"))
                }
                try render(DeviceProfileEditor(profile: DeviceProfile.presets[0], isNew: false).environment(controller),
                    size: CGSize(width: 560, height: 650), to: directory.appendingPathComponent("device-profile-editor.png"))
                try render(WorkProfileEditor(profile: WorkProfile.presets[0], isNew: false).environment(controller),
                    size: CGSize(width: 620, height: 720), to: directory.appendingPathComponent("work-profile-editor.png"))
                if let device = controller.devices.first {
                    try render(ScrollView { DeviceRow(device: device, onRemove: {}, expanded: true).padding(24) }.environment(controller),
                        size: CGSize(width: 680, height: 800), to: directory.appendingPathComponent("device-policy.png"))
                }
                if let job = controller.jobs.first(where: { $0.recipe != nil && $0.status.isFinished }) {
                    try render(RecipeSheet(job: job).environment(controller), size: CGSize(width: 620, height: 620),
                        to: directory.appendingPathComponent("production-recipe.png"))
                }
                if let template = controller.templates.first(where: { $0.capability == .imageCreate }) {
                    let report = try sampleHealthReport(template)
                    try render(WorkflowHealthSheet(template: template, initialReport: report).environment(controller), size: CGSize(width: 620, height: 680),
                        to: directory.appendingPathComponent("workflow-health.png"))
                    let missing = WorkflowInspector.inspect(template, objectInfo: [:], device: "mps")
                    try render(WorkflowHealthSheet(template: template, initialReport: missing).environment(controller), size: CGSize(width: 620, height: 680),
                        to: directory.appendingPathComponent("workflow-health-missing.png"))
                }
                try render(RootView(selection: .overview).environment(controller), size: CGSize(width: 860, height: 540),
                    to: directory.appendingPathComponent("overview-narrow.png"))
                try render(PlaygroundView.snapshot(mode: .image).environment(controller), size: CGSize(width: 780, height: 760),
                    to: directory.appendingPathComponent("playground-image.png"))
                try render(PlaygroundView.snapshot(mode: .chat, withResult: true).environment(controller), size: CGSize(width: 780, height: 640),
                    to: directory.appendingPathComponent("playground-chat.png"))
                let freshState = state.appendingPathComponent("fresh")
                let fresh = HubController(core: try HubCore(directory: freshState))
                spin(0.3)
                try render(SetupGuideView(navigate: { _ in }).environment(fresh), size: CGSize(width: 620, height: 660),
                    to: directory.appendingPathComponent("setup-guide.png"))
                try render(RootView(selection: .overview).environment(fresh), size: CGSize(width: 980, height: 760),
                    to: directory.appendingPathComponent("first-run.png"))
                print("Review snapshots written to \(directory.path)")
                return
            }
            for section in SidebarItem.allCases {
                try render(RootView(selection: section).environment(controller), size: CGSize(width: 980, height: 640),
                    to: directory.appendingPathComponent("\(section.rawValue).png"))
            }
            try render(IntegrationEditor(draft: ProviderConfiguration.defaults[0], isNew: true).environment(controller),
                size: CGSize(width: 520, height: 420), to: directory.appendingPathComponent("integration-editor.png"))
            if let template = core.integrations.templates.first(where: { $0.capability == .imageEdit }) {
                try render(TemplateEditor(template: template, isNew: false).environment(controller),
                    size: CGSize(width: 600, height: 640), to: directory.appendingPathComponent("workflow-editor.png"))
            }
            try render(ComfyImportSheet { _, _ in }.environment(controller), size: CGSize(width: 560, height: 480),
                to: directory.appendingPathComponent("comfy-import.png"))
            try render(MCPServerEditor(server: core.store.settings().mcpServers[0], originalID: "files").environment(controller),
                size: CGSize(width: 560, height: 600), to: directory.appendingPathComponent("mcp-editor.png"))
            if let log = try core.store.chatLogs().first {
                try render(ChatLogDetail(log: log), size: CGSize(width: 620, height: 520),
                    to: directory.appendingPathComponent("conversation-detail.png"))
            }
            Task { await controller.openPairing() }
            spin(0.5)
            try render(PairingView().environment(controller), size: CGSize(width: 420, height: 600),
                to: directory.appendingPathComponent("pairing.png"))
            print("Snapshots written to \(directory.path)")
        } catch {
            print("Snapshot failed: \(error)")
            exit(1)
        }
    }

    /// A workflow, two generated files and a few jobs so every screen has content.
    private static func seedSamples(_ core: HubCore) throws {
        let workflows = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../examples/workflows")
        for (id, file) in [("sdxl", "sdxl-text-to-image.json"), ("sdxl-inpaint", "sdxl-inpaint.json")] {
            let json = try String(contentsOf: workflows.appendingPathComponent(file), encoding: .utf8)
            let detected = try WorkflowGraph(json: json).detectSlots()
            try core.integrations.save(WorkflowTemplate(id: id, name: id == "sdxl" ? "SDXL text to image" : "SDXL inpaint",
                integrationID: "comfyui", capability: detected.capability, workflow: json, slots: detected.slots, outputNode: detected.outputNode))
        }
        var settings = try core.store.settings()
        settings.mcpServers = [MCPServerConfiguration(id: "files", executable: "/usr/bin/python3",
            arguments: ["-m", "mcp_files", "/Users/Shared/Art"], allowedTools: ["read_file", "list_directory"])]
        try core.store.save(settings)
        let device = try core.store.devices().first?.id
        for (index, sample) in [
            ("Explain the difference between a raster and a vector brush in two sentences.",
             "A raster brush paints pixels, so strokes lose sharpness when you scale them up. A vector brush stores the stroke as a path, so it stays crisp at any size.", "completed", true),
            ("Suggest three names for a watercolor fox series.", "Ember Trail, Snowlight Fox, Quiet Russet.", "completed", false),
            ("Translate “layer mask” to Turkish.", "", "error", false),
        ].enumerated() {
            let messages = [["role": "system", "content": "You help artists in ArtBlend."], ["role": "user", "content": sample.0]]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: messages), as: UTF8.self)
            try core.store.save(ChatLog(id: "chat-sample-\(index)", deviceID: device ?? "", deviceName: "MatePad 11", app: "artblend",
                model: "lmstudio/google/gemma-4-26b-a4b-qat", integrationID: "lmstudio", messages: json, prompt: sample.0,
                response: sample.1, finishReason: sample.2 == "completed" ? "stop" : nil, promptTokens: sample.2 == "completed" ? 42 : nil,
                completionTokens: sample.2 == "completed" ? 31 : nil, durationMs: 2350 + index * 900, status: sample.2,
                error: sample.2 == "error" ? "LM Studio is not running on this Mac (http://127.0.0.1:1234)" : nil, stream: sample.3,
                createdAt: Date().addingTimeInterval(Double(-index * 1800))))
        }
        for (index, hue) in [0.08, 0.55, 0.8].enumerated() {
            let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
                NSGradient(starting: NSColor(hue: hue, saturation: 0.7, brightness: 0.95, alpha: 1),
                           ending: NSColor(hue: hue + 0.1, saturation: 0.8, brightness: 0.5, alpha: 1))?.draw(in: rect, angle: 60)
                return true
            }
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let file = try core.files.create(deviceID: device, filename: "sdxl-\(index + 1).png", mime: "image/png", data: png,
                purpose: "output", source: "job", quota: .max)
            var job = HubJob(id: "job-sample-\(index)", deviceID: device ?? "", deviceName: "MatePad 11", capability: .imageCreate,
                model: "comfyui/sdxl", prompt: ["a watercolor fox", "neon city at dusk", "paper boat on a lake"][index],
                status: index == 0 ? .inProgress : .completed, progress: index == 0 ? 0.4 : 1, error: nil,
                outputFileIDs: index == 0 ? [] : [file.id], createdAt: Date().addingTimeInterval(Double(-index * 300 - 40)),
                finishedAt: index == 0 ? nil : Date().addingTimeInterval(Double(-index * 300)),
                startedAt: Date().addingTimeInterval(Double(-index * 300 - 30)), promptID: "4f2a-\(index)")
            if index == 0 { job.currentNode = "Sampler 12/30"; job.etaSeconds = 80 }
            if let template = core.integrations.templates.first(where: { $0.id == "sdxl" }) {
                var request = WorkflowJobRequest(prompt: job.prompt)
                request.seed = 42; request.steps = 20; request.width = 1024; request.height = 1024
                job.recipe = try JobRecipe(template: template, request: request)
            }
            try core.store.save(job)
        }
    }

    private static func sampleHealthReport(_ template: WorkflowTemplate) throws -> WorkflowHealthReport {
        let graph = try WorkflowGraph(json: template.workflow)
        var catalog: [String: Any] = [:]
        for node in graph.nodeList {
            var inputs: [String: Any] = [:]
            for name in graph.scalarInputs(of: node.id) {
                let value = graph.value(of: TemplateSlot(kind: .prompt, node: node.id, input: name))
                let type: String
                if let number = value as? NSNumber {
                    type = CFGetTypeID(number) == CFBooleanGetTypeID() ? "BOOLEAN" : number.doubleValue.rounded() == number.doubleValue ? "INT" : "FLOAT"
                } else { type = "STRING" }
                inputs[name] = [type, [:]] as [Any]
            }
            catalog[node.classType] = ["input": ["required": inputs], "output": ["ANY", "ANY", "ANY", "ANY"], "output_node": node.id == template.outputNode]
        }
        return WorkflowInspector.inspect(template, objectInfo: catalog, device: "mps")
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    nonisolated(unsafe) static var appearance: NSAppearance.Name = .aqua

    private static func render(_ view: some View, size: CGSize, to url: URL) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        spin(2.5)
        let bounds = host.bounds
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        host.cacheDisplay(in: bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
