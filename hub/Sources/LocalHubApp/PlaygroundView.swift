import AppKit
import AVKit
import LocalHubClient
import LocalHubCore
import SwiftUI
import UniformTypeIdentifiers

/// Every run uses the same pinned API and permissions as paired devices.
struct PlaygroundView: View {
    @Environment(HubController.self) private var hub
    var navigate: (SidebarItem) -> Void = { _ in }
    private var preferredProviderID: String?

    init(navigate: @escaping (SidebarItem) -> Void = { _ in }, capability: Capability? = nil, providerID: String? = nil) {
        self.navigate = navigate
        preferredProviderID = providerID
        _mode = State(initialValue: Mode.allCases.first { $0.capability == capability } ?? .chat)
    }

    enum Mode: String, CaseIterable, Identifiable {
        case chat = "Chat", image = "Create image", edit = "Edit image", speech = "Speak", audio = "Create audio",
             video = "Create video", model3D = "3D from image", transcribe = "Transcribe", embeddings = "Embeddings"
        var id: Self { self }
        var capability: Capability {
            switch self {
            case .chat: .chat
            case .image: .imageCreate
            case .edit: .imageEdit
            case .speech: .audioSpeech
            case .audio: .audioCreate
            case .video: .videoCreate
            case .model3D: .model3DCreate
            case .transcribe: .audioTranscribe
            case .embeddings: .embeddings
            }
        }
        var needsFile: Bool { self == .edit || self == .model3D || self == .transcribe }
        var fileTypes: [UTType] { self == .transcribe ? [.audio] : [.png, .jpeg, .webP] }
        var examples: [String] {
            switch self {
            case .chat: ["Suggest three names for a watercolor fox series.", "Explain layer masks to a beginner in two sentences."]
            case .image: ["A watercolor fox in a snowy forest, soft morning light", "A paper boat on a quiet lake, pastel illustration"]
            case .edit: ["Replace the background with a misty forest", "Turn this image into a watercolor painting"]
            case .speech: ["Welcome to your local creative studio.", "Your next idea starts here."]
            case .audio: ["Gentle rain on a window with distant thunder", "A calm ambient piano melody"]
            case .video: ["A paper boat drifting across a lake at sunrise", "Slow camera movement through a misty forest"]
            case .embeddings: ["A watercolor painting of a fox in winter"]
            case .model3D, .transcribe: []
            }
        }
    }

    enum Output {
        case text(String, thinking: String)
        case image(NSImage)
        case media(URL)
        case file(LocalHubCore.HubFile)
    }

    struct ChatTurn: Identifiable {
        let id = UUID()
        let prompt: String
        let response: String
        let thinking: String
    }

    private struct ImageParameters: Sendable {
        let enabled: Bool
        let steps: Int
        let seed: String
        let negativePrompt: String

        nonisolated var extra: [String: Any] {
            guard enabled else { return [:] }
            var parameters: [String: Any] = ["steps": steps]
            if let value = UInt32(seed) { parameters["seed"] = Int(value) }
            if !negativePrompt.isEmpty { parameters["negative_prompt"] = negativePrompt }
            return parameters
        }
    }

    @State private var mode: Mode = .chat
    @State private var model = ""
    @State private var profileID = ""
    @State private var prompt = ""
    @State private var input: URL?
    @State private var mask: URL?
    @State private var output: Output?
    @State private var turns: [ChatTurn] = []
    @State private var currentPrompt: String?
    @State private var error: String?
    @State private var running: Task<Void, Never>?
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval?
    @State private var cancelled = false
    @State private var activeVideoID: String?
    @State private var player: AVPlayer?
    @State private var customImageSettings = false
    @State private var imageOptionsExpanded = false
    @State private var imageSize = ""
    @State private var seed = ""
    @State private var steps = 20
    @State private var negativePrompt = ""
    @State private var dragTargeted = false

    private var choices: [LocalHubClient.HubModel] {
        hub.playgroundModels.filter { item in
            item.capabilities.contains(mode.capability.rawValue)
                && hub.statuses[item.provider]?.state == "running"
        }
    }
    private var needsConcreteModel: Bool { mode == .chat || mode == .embeddings }
    private var available: Bool {
        hub.readyCapabilities.contains(mode.capability) && (mode == .transcribe || !choices.isEmpty)
    }
    private var inputReady: Bool {
        switch mode {
        case .model3D: input != nil
        case .edit: input != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .transcribe: input != nil
        default: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    private var seedValid: Bool {
        !customImageSettings || (mode != .image && mode != .edit) || seed.isEmpty
            || UInt32(seed) != nil
    }
    private var ready: Bool {
        hub.isRunning && available && inputReady && seedValid
            && workflowWarning == nil && !selectedModelUnavailable && (!needsConcreteModel || choices.contains { $0.id == model })
    }
    private var selectedProfile: WorkProfile? { hub.settings.workProfiles.first { $0.id == profileID } }
    private var selectedModelUnavailable: Bool { mode != .transcribe && !model.isEmpty && !choices.contains { $0.id == model } }
    private var selectedWorkflow: WorkflowTemplate? {
        let wanted = model.isEmpty ? hub.settings.defaults[mode.capability.rawValue] : model
        let candidates = hub.templates.filter { $0.capability == mode.capability }
        if let wanted { return candidates.first { "\($0.integrationID)/\($0.id)" == wanted } }
        return candidates.count == 1 ? candidates.first : nil
    }
    private var workflowWarning: String? {
        guard let template = selectedWorkflow else { return nil }
        return template.unsupportedModelWarning(device: hub.comfyDevices[template.integrationID])
    }
    private var ambiguousDefault: Bool {
        !needsConcreteModel && mode != .transcribe && model.isEmpty && selectedWorkflow == nil
    }

    var body: some View {
        HSplitView {
            inputPanel.frame(minWidth: 300, idealWidth: 340, maxWidth: 410)
            resultPanel.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Playground")
        .navigationSubtitle("Try your local AI · Requests stay on your hub")
        .toolbar {
            ToolbarItem {
                Button("Refresh Models", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }.disabled(hub.loadingModels || running != nil || !hub.isRunning)
            }
            ToolbarItem {
                if mode == .chat {
                    Button("New Chat", systemImage: "square.and.pencil") { resetResult(); turns = []; prompt = "" }
                        .disabled(running != nil || (turns.isEmpty && output == nil))
                }
            }
        }
        .task(id: hub.isRunning) {
            if !hub.isRunning { running?.cancel() }
            await refresh()
        }
        .onChange(of: hub.playgroundModels) { reconcileModel() }
        .onChange(of: mode) {
            resetResult(); turns = []; input = nil; mask = nil; prompt = ""
            model = ""
            reconcileModel()
            applyProfileModel()
        }
        .onChange(of: profileID) { resetResult(); turns = []; applyProfileModel() }
        .onChange(of: hub.settings.workProfiles) { if selectedProfile == nil { profileID = "" } }
        .onChange(of: model) { resetResult(); turns = [] }
        .onDisappear { running?.cancel(); player?.pause() }
    }

    private var inputPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Make something", systemImage: "sparkles").font(.title3.weight(.semibold))
                    Text("One place to try everything your Mac can do.").font(.callout).foregroundStyle(.secondary)
                }
                prerequisites
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Capability", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Work profile", selection: $profileID) {
                        Text("Workflow / hub defaults").tag("")
                        ForEach(hub.settings.workProfiles) { Text($0.name).tag($0.id) }
                    }
                    if let selectedProfile {
                        HStack {
                            Text(profileSummary(selectedProfile)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit Profiles") { navigate(.profiles) }.buttonStyle(.link).font(.caption)
                        }
                    }
                    if mode != .transcribe {
                        Picker("Model", selection: $model) {
                            if choices.isEmpty && model.isEmpty { Text(hub.loadingModels ? "Loading models…" : "No model available").tag("") }
                            else if !needsConcreteModel { Text("Workflow default").tag("") }
                            if !model.isEmpty && !choices.contains(where: { $0.id == model }) {
                                Text("\(model) (unavailable)").tag(model)
                            }
                            ForEach(choices) { item in Text(item.id).tag(item.id) }
                        }
                        if let chosen = choices.first(where: { $0.id == model }), chosen.loaded == false {
                            Text("This model will load on its first request.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if mode != .model3D && mode != .transcribe {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(mode == .speech ? "Text to speak" : turns.isEmpty ? "Prompt" : "Follow-up message")
                                .font(.callout.weight(.medium))
                            TextField("Describe what you have in mind…", text: $prompt, axis: .vertical)
                                .lineLimit(5...12).textFieldStyle(.plain)
                                .padding(12).frame(maxWidth: .infinity, alignment: .topLeading)
                                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.12)))
                        }
                        if !mode.examples.isEmpty {
                            Menu {
                                ForEach(mode.examples, id: \.self) { example in Button(example) { prompt = example } }
                            } label: { Label("Use an example", systemImage: "lightbulb") }
                            .menuStyle(.borderlessButton).fixedSize()
                        }
                    }
                    if mode.needsFile { fileInput }
                    if mode == .image || mode == .edit { imageOptions }
                }
                .disabled(running != nil)
                if let error {
                    HubCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Something needs attention", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.medium)).foregroundStyle(.orange)
                            Text(error).font(.caption).textSelection(.enabled)
                            Text("Check the local app and selected model, then try again.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Check Integrations") { navigate(.integrations) }.buttonStyle(.link)
                            Button("Run Diagnostics") { navigate(.diagnostics) }.buttonStyle(.link)
                        }
                    }
                }
                HStack {
                    Text(running != nil ? "Working on your Mac…" : "⌘ Return to run")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if running != nil { Button("Stop", role: .destructive) { running?.cancel() } }
                    Button(mode == .chat && !turns.isEmpty ? "Send" : "Run", systemImage: "arrow.up") { run() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(running != nil || !ready || ambiguousDefault)
                }
            }
            .padding(20)
        }
        .background(.background.secondary)
    }

    @ViewBuilder private var prerequisites: some View {
        if !hub.isRunning {
            HubCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Start your hub", systemImage: "power").font(.headline)
                    Text("Your local apps connect through LocalHub. Start it to discover models and run a prompt.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(hub.serverState == .starting ? "Starting…" : "Start Hub") { Task { await hub.start() } }
                        .buttonStyle(.borderedProminent).disabled(hub.serverState == .starting)
                    if case .failed(let reason) = hub.serverState {
                        Text(reason).font(.caption).foregroundStyle(.orange)
                        Button("Open Settings") { navigate(.settings) }.buttonStyle(.link)
                    }
                }
            }
        } else if hub.loadingModels && choices.isEmpty {
            HStack { ProgressView().controlSize(.small); Text("Discovering models…").font(.callout).foregroundStyle(.secondary) }
        } else if !available || ambiguousDefault || workflowWarning != nil || selectedModelUnavailable {
            HubCard {
                VStack(alignment: .leading, spacing: 8) {
                    Label(ambiguousDefault && available ? "Choose a workflow" : "Set up \(mode.rawValue.lowercased())",
                          systemImage: "info.circle").font(.headline)
                    Text(prerequisiteMessage).font(.callout).foregroundStyle(.secondary)
                    if let modelError = hub.modelError { Text(modelError).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button(needsConcreteModel || mode == .transcribe ? "Open Integrations" : "Open Workflows") {
                            navigate(needsConcreteModel || mode == .transcribe ? .integrations : .workflows)
                        }
                        Button("Refresh") { Task { await refresh() } }
                    }
                }
            }
        }
    }

    private var prerequisiteMessage: String {
        if selectedModelUnavailable { return "The selected profile/model is unavailable. Start its local service, choose another model, or edit the profile." }
        if let workflowWarning { return workflowWarning }
        if ambiguousDefault && available { return "Select a workflow below or set a default in Workflows before running." }
        if needsConcreteModel { return "Start LM Studio or Ollama with a model and enable its local server, then refresh." }
        if mode == .transcribe { return "Connect a Whisper transcription server in Integrations to transcribe audio." }
        return "Start ComfyUI and import a compatible workflow in Workflows, then refresh."
    }

    private var fileInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { choose(mask: false) } label: {
                VStack(spacing: 8) {
                    if mode != .transcribe, let input, let image = NSImage(contentsOf: input) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 100)
                    } else {
                        Image(systemName: mode == .transcribe ? "waveform" : "photo.badge.plus").font(.title2)
                    }
                    Text(input?.lastPathComponent ?? (mode == .transcribe ? "Choose or drop audio" : "Choose or drop an image"))
                        .font(.caption).lineLimit(2)
                }
                .frame(maxWidth: .infinity).padding(16)
                .background(Color.accentColor.opacity(dragTargeted ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
            .buttonStyle(.plain)
            .dropDestination(for: URL.self) { urls, _ in
                guard running == nil, let url = urls.first, accepts(url) else { return false }
                input = url; mask = nil
                return true
            } isTargeted: { dragTargeted = $0 }
            if mode == .edit {
                HStack {
                    Text(mask?.lastPathComponent ?? "Mask (optional)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if mask != nil { Button("Remove") { mask = nil }.controlSize(.small) }
                    Button("Choose Mask…") { choose(mask: true) }.controlSize(.small)
                }
                Text("Mask meaning follows your workflow. Without a mask, the image's alpha channel is used when supported.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var imageOptions: some View {
        DisclosureGroup("Image settings", isExpanded: $imageOptionsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Override workflow defaults", isOn: $customImageSettings)
                if customImageSettings {
                    if mode == .image {
                        Picker("Size", selection: $imageSize) {
                            Text("Workflow default").tag("")
                            Text("512 × 512").tag("512x512")
                            Text("768 × 768").tag("768x768")
                            Text("1024 × 1024").tag("1024x1024")
                            Text("768 × 1024").tag("768x1024")
                            Text("1024 × 768").tag("1024x768")
                        }
                    }
                    Stepper("Steps: \(steps)", value: $steps, in: 1...150)
                    TextField("Seed (blank keeps workflow default)", text: $seed).textFieldStyle(.roundedBorder)
                    if !seedValid { Text("Seed must be a whole number from 0 to 4294967295.").font(.caption).foregroundStyle(.orange) }
                    TextField("Negative prompt (optional)", text: $negativePrompt, axis: .vertical).textFieldStyle(.roundedBorder)
                    Text("Options only affect inputs mapped by the selected workflow.").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(selectedProfile == nil ? "The workflow's original size, seed and sampling settings are preserved." : "The selected profile supplies defaults. Enable overrides to change them for this request.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.top, 10)
        }
        .font(.callout)
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label(mode == .chat ? "Conversation" : "Result", systemImage: mode.capability.symbol)
                    .font(.headline)
                Spacer()
                if let elapsed { Text(HubJob.format(elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if output != nil || !turns.isEmpty {
                    Button("Copy", systemImage: "doc.on.doc") { copyOutput() }.labelStyle(.iconOnly).help("Copy result")
                    Button("Save", systemImage: "square.and.arrow.down") { saveOutput() }.labelStyle(.iconOnly).help("Save result…")
                }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if mode == .chat {
                        ForEach(turns) { turn in
                            chatMessage(role: "You", text: turn.prompt)
                            thinkingView(turn.thinking)
                            chatMessage(role: "Assistant", text: turn.response)
                        }
                        if let currentPrompt { chatMessage(role: "You", text: currentPrompt) }
                    }
                    if running != nil {
                        if let job = playgroundJob, !job.status.isFinished {
                            ProgressView(value: job.progress ?? 0)
                            Text(job.activityLine).font(.caption).foregroundStyle(.secondary)
                            if let data = hub.previews[job.id], let image = NSImage(data: data) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                            }
                        } else {
                            HStack { ProgressView().controlSize(.small); Text("Creating on your Mac…").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    outputView
                    if cancelled {
                        Label("Stopped. You can edit your input and try again.", systemImage: "stop.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var outputView: some View {
        switch output {
        case .text(let text, let thinking)?:
            thinkingView(thinking)
            if mode == .chat { chatMessage(role: "Assistant", text: text) }
            else { Text(text).textSelection(.enabled) }
        case .image(let image)?:
            Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
        case .media?:
            if let player { VideoPlayer(player: player).frame(minHeight: 280) }
        case .file(let file)?:
            Label("\(file.filename) · \(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file))", systemImage: "cube")
            HStack {
                Button("Open") { NSWorkspace.shared.open(hub.core.files.contentURL(file)) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hub.core.files.contentURL(file)]) }
            }
        case nil:
            if running == nil && turns.isEmpty && !cancelled {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: mode.capability.symbol).font(.system(size: 40)).foregroundStyle(.tint)
                        .padding(18).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                    Text("A little curiosity goes a long way.").font(.title2.weight(.semibold))
                    Text(mode.needsFile ? "Choose a file on the left, then run your first request." : "Write a prompt or start with an example. Your result will appear here.")
                        .foregroundStyle(.secondary)
                    if let example = mode.examples.first {
                        Button { prompt = example } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Try this", systemImage: "lightbulb").font(.caption.weight(.medium))
                                Text(example).font(.callout).multilineTextAlignment(.leading)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                        .disabled(running != nil)
                    }
                }
                .padding(.top, 35).frame(maxWidth: 440, alignment: .leading)
            }
        }
    }

    private func chatMessage(role: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(role == "You" ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private func thinkingView(_ text: String) -> some View {
        if !text.isEmpty {
            DisclosureGroup("Thinking") { Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private var playgroundJob: LocalHubCore.HubJob? {
        hub.jobs.first { $0.deviceName == "Playground (this Mac)" && $0.createdAt >= (startedAt ?? .distantFuture) }
    }

    private func refresh() async {
        guard hub.isRunning else { return }
        await hub.refreshStatuses()
        await hub.refreshModels()
        await hub.refreshComfyDevices()
        reconcileModel()
    }

    private func reconcileModel() {
        guard running == nil else { return }
        // Keep a conversation intact when its provider temporarily goes offline.
        if model.isEmpty, let preferred = choices.first(where: { $0.provider == preferredProviderID }) { model = preferred.id }
        if needsConcreteModel && model.isEmpty { model = choices.first?.id ?? "" }
    }

    private func applyProfileModel() {
        guard running == nil else { return }
        if let chosen = selectedProfile?.models[mode.capability.rawValue] { model = chosen }
        else { model = ""; reconcileModel() }
    }

    private func profileSummary(_ profile: WorkProfile) -> String {
        var parts: [String] = []
        if let steps = profile.steps { parts.append("\(steps) steps") }
        if let width = profile.width, let height = profile.height { parts.append("\(width) × \(height)") }
        if profile.schedule == .night && !needsConcreteModel && mode != .transcribe {
            parts.append("night hours \(hub.settings.queue.nightStartHour):00–\(hub.settings.queue.nightEndHour):00 · follow in Jobs")
        }
        return parts.isEmpty ? "Saved model and workflow defaults" : parts.joined(separator: " · ")
    }

    private func accepts(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return mode.fileTypes.contains { type.conforms(to: $0) }
    }

    private func choose(mask choosingMask: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = choosingMask ? [.png, .jpeg, .webP] : mode.fileTypes
        if panel.runModal() == .OK {
            if choosingMask { mask = panel.url } else { input = panel.url; mask = nil }
        }
    }

    private func resetResult() {
        player?.pause(); player = nil
        output = nil; error = nil; elapsed = nil; currentPrompt = nil; cancelled = false
    }

    private func run() {
        guard running == nil, ready, !ambiguousDefault else { return }
        resetResult()
        startedAt = Date()
        let mode = mode, model = model.isEmpty ? nil : model, requestPrompt = prompt, input = input, mask = mask
        let profileID = profileID
        let history = turns.flatMap { [ChatMessage.user($0.prompt), ChatMessage(role: "assistant", content: $0.response)] }
        let options = ImageParameters(enabled: customImageSettings, steps: steps, seed: seed, negativePrompt: negativePrompt)
        let size = customImageSettings && !imageSize.isEmpty ? imageSize : nil
        if mode == .chat { currentPrompt = requestPrompt }
        running = Task {
            defer {
                elapsed = startedAt.map { Date().timeIntervalSince($0) }
                activeVideoID = nil
                running = nil
            }
            do {
                let client = try await hub.playgroundClient()
                switch mode {
                case .chat:
                    var text = "", thinking = ""
                    for try await delta in try await client.chatStream(ChatRequest(model: model, messages: history + [.user(requestPrompt)], profile: profileID)) {
                        try Task.checkCancellation()
                        text += delta.content; thinking += delta.reasoning
                        output = .text(text, thinking: thinking)
                    }
                    try Task.checkCancellation()
                    turns.append(ChatTurn(prompt: requestPrompt, response: text, thinking: thinking))
                    output = nil; currentPrompt = nil; prompt = ""
                case .embeddings:
                    let vectors = try await client.embeddings(model: model ?? "", input: [requestPrompt], profile: profileID)
                    let vector = vectors.first ?? []
                    output = .text("\(vector.count) dimensions\n" + vector.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: ", ") + " …", thinking: "")
                case .image:
                    try show(try await client.generateImage(prompt: requestPrompt, model: model, size: size, extra: options.extra, profile: profileID))
                case .edit:
                    guard let input else { throw ConfigurationError.invalid("Choose an image first") }
                    let imageInput = try mediaInput(input)
                    let maskInput = try mask.map { try mediaInput($0) }
                    try show(try await client.editImage(prompt: requestPrompt, image: imageInput, mask: maskInput, model: model, extra: options.extra, profile: profileID))
                case .speech:
                    let (data, type) = try await client.speech(requestPrompt, model: model, profile: profileID)
                    setMedia(try temporary(data, ext: type.contains("wav") ? "wav" : type.contains("mpeg") ? "mp3" : "flac"))
                case .audio:
                    try show(try await client.generateAudio(prompt: requestPrompt, model: model, profile: profileID))
                case .video:
                    var video = try await client.createVideo(prompt: requestPrompt, model: model, profile: profileID)
                    activeVideoID = video.id
                    while video.status == "queued" || video.status == "in_progress" {
                        try await Task.sleep(for: .seconds(1))
                        video = try await client.video(video.id)
                    }
                    guard video.status == "completed" else { throw ConfigurationError.invalid("The video \(video.status). Check Jobs for details.") }
                    setMedia(try temporary(try await client.videoContent(video.id), ext: "mp4"))
                case .model3D:
                    guard let input else { throw ConfigurationError.invalid("Choose an image first") }
                    try show(try await client.generate3D(image: try mediaInput(input), prompt: requestPrompt.isEmpty ? nil : requestPrompt, model: model, profile: profileID))
                case .transcribe:
                    guard let input else { throw ConfigurationError.invalid("Choose an audio file first") }
                    output = .text(try await client.transcribe(try Data(contentsOf: input), filename: input.lastPathComponent, profile: profileID), thinking: "")
                }
                try Task.checkCancellation()
                hub.completePlaygroundRun()
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    cancelled = true
                    if let videoID = activeVideoID {
                        // Cleanup runs outside the cancelled task so its HTTP request can finish.
                        let core = hub.core
                        _ = await Task.detached { await core.jobs.cancel(videoID, deviceID: nil) }.value
                    }
                } else {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func mediaInput(_ url: URL) throws -> MediaInput {
        guard let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType else {
            throw ConfigurationError.invalid("The image format could not be identified")
        }
        return .data(try Data(contentsOf: url), filename: url.lastPathComponent, contentType: type)
    }

    private func show(_ result: MediaResult) throws {
        hub.refreshFiles()
        guard let item = result.items.first else { throw ConfigurationError.invalid("The workflow returned no output") }
        if let file = hub.files.first(where: { $0.id == item.fileID }) {
            if file.mime.hasPrefix("image/"), let image = NSImage(contentsOf: hub.core.files.contentURL(file)) { output = .image(image) }
            else if file.mime.hasPrefix("audio/") || file.mime.hasPrefix("video/") { setMedia(hub.core.files.contentURL(file)) }
            else { output = .file(file) }
        } else if let data = item.data, let image = NSImage(data: data) {
            output = .image(image)
        } else { throw ConfigurationError.invalid("The generated file is unavailable. Check Files or run the request again.") }
    }

    private func setMedia(_ url: URL) {
        player?.pause()
        output = .media(url)
        player = AVPlayer(url: url)
    }

    private var textResult: String? {
        if mode == .chat {
            let history = turns.map { "You: \($0.prompt)\n\nAssistant: \($0.response)" }.joined(separator: "\n\n")
            if case .text(let text, _) = output { return history + (history.isEmpty ? "" : "\n\n") + "You: \(currentPrompt ?? "")\n\nAssistant: \(text)" }
            return history.isEmpty ? nil : history
        }
        if case .text(let text, _) = output { return text }
        return nil
    }

    private func copyOutput() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let text = textResult { pasteboard.setString(text, forType: .string) }
        else if case .image(let image) = output { pasteboard.writeObjects([image]) }
        else if let url = outputURL { pasteboard.writeObjects([url as NSURL]) }
    }

    private var outputURL: URL? {
        switch output {
        case .media(let url): url
        case .file(let file): hub.core.files.contentURL(file)
        default: nil
        }
    }

    private func saveOutput() {
        let panel = NSSavePanel()
        if textResult != nil { panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = mode == .chat ? "conversation.txt" : "result.txt" }
        else if case .image = output { panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "localhub-image.png" }
        else if let url = outputURL {
            panel.nameFieldStringValue = url.lastPathComponent
            if let type = UTType(filenameExtension: url.pathExtension) { panel.allowedContentTypes = [type] }
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if let text = textResult { try text.write(to: destination, atomically: true, encoding: .utf8) }
            else if case .image(let image) = output, let tiff = image.tiffRepresentation,
                    let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: destination, options: .atomic)
            } else if let source = outputURL, source.standardizedFileURL != destination.standardizedFileURL {
                try Data(contentsOf: source).write(to: destination, options: .atomic)
            }
        } catch { self.error = HubController.describe(error) }
    }

    private func temporary(_ data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("localhub-playground-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    /// Deterministic display states for the app's temporary-state snapshot runner.
    static func snapshot(mode: Mode, withResult: Bool = false) -> PlaygroundView {
        var view = PlaygroundView(capability: mode.capability)
        view._prompt = State(initialValue: mode.examples.first ?? "")
        if mode == .image {
            view._imageOptionsExpanded = State(initialValue: true)
            view._customImageSettings = State(initialValue: true)
            view._seed = State(initialValue: "42")
            view._imageSize = State(initialValue: "1024x1024")
        }
        if withResult {
            view._turns = State(initialValue: [ChatTurn(prompt: "Suggest three names for a watercolor fox series.",
                response: "Ember Trail, Snowlight Fox, Quiet Russet.", thinking: "Short, evocative names suit a watercolor collection.")])
            view._prompt = State(initialValue: "Give me a color palette for Snowlight Fox.")
            view._elapsed = State(initialValue: 2.4)
        }
        return view
    }
}
