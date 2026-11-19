import Foundation

/// What a client asks for. Which integration answers is decided on the Mac.
public enum Capability: String, Codable, CaseIterable, Sendable, Identifiable {
    case chat
    case imageCreate = "image.create"
    case imageEdit = "image.edit"
    case audioSpeech = "audio.speech"
    case audioCreate = "audio.create"
    case audioEdit = "audio.edit"
    case videoCreate = "video.create"
    case videoEdit = "video.edit"
    case model3DCreate = "3d.create"
    case embeddings
    case audioTranscribe = "audio.transcribe"

    public var id: Self { self }
    public var title: String {
        switch self {
        case .chat: "Chat"
        case .imageCreate: "Create images"
        case .imageEdit: "Edit images"
        case .audioSpeech: "Speak text"
        case .audioCreate: "Create audio"
        case .audioEdit: "Edit audio"
        case .videoCreate: "Create videos"
        case .videoEdit: "Edit videos"
        case .model3DCreate: "Create 3D models"
        case .embeddings: "Embeddings"
        case .audioTranscribe: "Transcribe audio"
        }
    }
    /// Capabilities a ComfyUI workflow can provide (the others come from OpenAI-compatible or Whisper apps).
    public static let workflowCapabilities: [Capability] = [.imageCreate, .imageEdit, .audioSpeech, .audioCreate, .audioEdit,
                                                            .videoCreate, .videoEdit, .model3DCreate]

    /// Minutes a workflow of this kind may run by default (video on a laptop is slow).
    public var defaultTimeoutMinutes: Int {
        switch self {
        case .videoCreate, .videoEdit: 60
        case .audioCreate, .audioEdit, .model3DCreate: 20
        default: 10
        }
    }

    /// The input slot an edit workflow cannot run without.
    public var requiredInput: SlotKind? {
        switch self {
        case .imageEdit: .image
        case .audioEdit: .audio
        case .videoEdit: .video
        default: nil
        }
    }
}

extension ProviderKind {
    public var capabilities: [Capability] {
        switch self {
        case .openai: [.chat, .embeddings]
        case .comfyui: Capability.workflowCapabilities
        case .whisper: [.audioTranscribe]
        }
    }
}

public enum SlotKind: String, Codable, CaseIterable, Sendable {
    case prompt, negativePrompt = "negative_prompt", seed, steps, width, height, denoise, seconds, frames, fps
    case image, mask, audio, video

    public var title: String {
        switch self {
        case .prompt: "Prompt"
        case .negativePrompt: "Negative prompt"
        case .seed: "Seed"
        case .steps: "Steps"
        case .width: "Width"
        case .height: "Height"
        case .denoise: "Denoise"
        case .seconds: "Duration (seconds)"
        case .frames: "Frames"
        case .fps: "Frame rate"
        case .image: "Input image"
        case .mask: "Mask"
        case .audio: "Input audio"
        case .video: "Input video"
        }
    }
}

/// Where a request value goes in the workflow: `nodes[node].inputs[input]`.
public struct TemplateSlot: Codable, Sendable, Equatable, Hashable {
    public var kind: SlotKind
    public var node: String
    public var input: String
    public init(kind: SlotKind, node: String, input: String) { self.kind = kind; self.node = node; self.input = input }
}

/// A ComfyUI workflow (API format) exposed as one capability. Clients never
/// send workflows; they fill these mapped slots only.
public struct WorkflowTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var integrationID: String
    public var capability: Capability
    public var workflow: String
    public var slots: [TemplateSlot]
    public var outputNode: String?
    /// How long a run may take before it is stopped in ComfyUI; `nil` uses the capability's default.
    public var timeoutMinutes: Int?

    public init(id: String, name: String, integrationID: String, capability: Capability, workflow: String,
                slots: [TemplateSlot], outputNode: String?, timeoutMinutes: Int? = nil) {
        self.id = id; self.name = name; self.integrationID = integrationID; self.capability = capability
        self.workflow = workflow; self.slots = slots; self.outputNode = outputNode; self.timeoutMinutes = timeoutMinutes
    }

    public var effectiveTimeout: TimeInterval { Double(timeoutMinutes ?? capability.defaultTimeoutMinutes) * 60 }

    public func slot(_ kind: SlotKind) -> TemplateSlot? { slots.first { $0.kind == kind } }

    public var fp8Models: [String] { (try? WorkflowGraph(json: workflow))?.fp8Models ?? [] }

    /// A warning when the template loads fp8 weights and ComfyUI runs on `device` `mps` (Apple Silicon).
    public func unsupportedModelWarning(device: String?) -> String? {
        guard device == "mps", !fp8Models.isEmpty else { return nil }
        return WorkflowTemplate.fp8Message(fp8Models)
    }

    static func fp8Message(_ files: [String]) -> String {
        let named = files.isEmpty ? "A model in this workflow" : files.joined(separator: ", ")
        return "\(named) has fp8 weights, which ComfyUI can't run on Apple Silicon (MPS). Use a bf16 or fp16 version of the model in this workflow."
    }

    public func validate() throws {
        guard id.range(of: #"^[a-z0-9][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil else {
            throw ConfigurationError.invalid("Template ID must use only a–z, 0–9 and -")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 60 else {
            throw ConfigurationError.invalid("Template name must be 1–60 characters")
        }
        guard Capability.workflowCapabilities.contains(capability) else {
            throw ConfigurationError.invalid("Chat runs on OpenAI-compatible integrations, not workflows")
        }
        let graph = try WorkflowGraph(json: workflow)
        guard slot(.prompt) != nil || (capability == .model3DCreate && slot(.image) != nil) else {
            throw ConfigurationError.invalid("Map the Prompt slot to a text input")
        }
        if let required = capability.requiredInput, slot(required) == nil {
            throw ConfigurationError.invalid("\(capability.title) needs the \(required.title) slot mapped")
        }
        for slot in slots {
            guard graph.scalarInputs(of: slot.node).contains(slot.input) else {
                throw ConfigurationError.invalid("\(slot.kind.title): node \(slot.node) has no input “\(slot.input)”")
            }
        }
        if let timeoutMinutes, !(1...720).contains(timeoutMinutes) {
            throw ConfigurationError.invalid("Timeout must be 1–720 minutes")
        }
        if let outputNode, graph.classType(of: outputNode) == nil {
            throw ConfigurationError.invalid("Output node \(outputNode) does not exist")
        }
    }
}

/// A ComfyUI API-format graph: `{"<node id>": {"class_type": …, "inputs": {…}}}`.
public struct WorkflowGraph {
    private var nodes: [String: [String: Any]]

    public init(json: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ConfigurationError.invalid("The file is not a JSON workflow")
        }
        if object["nodes"] is [Any] {
            throw ConfigurationError.invalid("This is a UI workflow. In ComfyUI choose Workflow › Export (API) and import that file.")
        }
        var nodes: [String: [String: Any]] = [:]
        for (id, value) in object {
            guard let node = value as? [String: Any], node["class_type"] is String, node["inputs"] is [String: Any] else {
                throw ConfigurationError.invalid("Node \(id) is not an API-format ComfyUI node")
            }
            nodes[id] = node
        }
        guard !nodes.isEmpty else { throw ConfigurationError.invalid("The workflow has no nodes") }
        self.nodes = nodes
    }

    /// Model files loaded with fp8 weights, by file name (`fp8`, `float8`, `e4m3`, `e5m2`) or a loader's fp8
    /// `weight_dtype`. PyTorch's MPS backend has no Float8 types, so ComfyUI on Apple Silicon cannot run them.
    public var fp8Models: [String] {
        let extensions = [".safetensors", ".sft", ".ckpt", ".pt", ".pth", ".bin", ".gguf"]
        let markers = ["fp8", "float8", "e4m3", "e5m2"]
        var found: [String] = []
        for id in nodes.keys.sorted() {
            guard let inputs = nodes[id]?["inputs"] as? [String: Any] else { continue }
            let fp8Dtype = (inputs["weight_dtype"] as? String)?.lowercased().hasPrefix("fp8") == true
            for case let value as String in inputs.values {
                let name = value.lowercased()
                guard extensions.contains(where: name.hasSuffix) else { continue }
                if (fp8Dtype || markers.contains(where: name.contains)) && !found.contains(value) { found.append(value) }
            }
        }
        return found
    }

    /// Node ids in numeric order with their class and optional `_meta.title`.
    public var nodeList: [(id: String, classType: String, title: String?)] {
        nodes.keys.sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }.map { id in
            (id, classType(of: id) ?? "?", (nodes[id]?["_meta"] as? [String: Any])?["title"] as? String)
        }
    }

    public func classType(of node: String) -> String? { nodes[node]?["class_type"] as? String }

    private func inputs(of node: String) -> [String: Any] { nodes[node]?["inputs"] as? [String: Any] ?? [:] }

    /// The literal value the exported workflow carries for a slot, e.g. its default fps.
    public func value(of slot: TemplateSlot) -> Any? { inputs(of: slot.node)[slot.input] }

    /// Inputs holding a literal value (not a `[node, output]` link).
    public func scalarInputs(of node: String) -> [String] {
        inputs(of: node).filter { !Self.isLink($0.value) }.map(\.key).sorted()
    }

    private static func isLink(_ value: Any) -> Bool {
        guard let array = value as? [Any], array.count == 2, array[0] is String else { return false }
        return array[1] is Int || array[1] is NSNumber
    }

    private func linkedNode(_ value: Any?) -> String? {
        guard let value, Self.isLink(value) else { return nil }
        return (value as? [Any])?.first as? String
    }

    /// Where a value really lives: the input itself when literal, or the primitive node
    /// (`PrimitiveInt`, `PrimitiveStringMultiline`, …) wired into it.
    private func literal(_ node: String, _ input: String) -> TemplateSlot? {
        guard let value = inputs(of: node)[input] else { return nil }
        if !Self.isLink(value) { return .init(kind: .prompt, node: node, input: input) }
        guard let source = linkedNode(value) else { return nil }
        let scalars = scalarInputs(of: source)
        return ["value", "string", "text", "int", "float", input].first(where: scalars.contains)
            .map { .init(kind: .prompt, node: source, input: $0) }
    }

    /// Guesses slots for common graphs: KSampler or SamplerCustomAdvanced (+ guider, noise,
    /// scheduler), text encoders, latent size, primitives, loaders and save nodes.
    public func detectSlots() -> (slots: [TemplateSlot], outputNode: String?, capability: Capability) {
        var slots: [TemplateSlot] = []
        func add(_ kind: SlotKind, _ found: TemplateSlot?) {
            guard let found, !slots.contains(where: { $0.kind == kind || ($0.node == found.node && $0.input == found.input) }) else { return }
            slots.append(.init(kind: kind, node: found.node, input: found.input))
        }
        func firstLiteral(_ names: [String], where include: (String) -> Bool = { _ in true }) -> TemplateSlot? {
            for node in nodeList where include(node.classType) {
                for name in names { if let found = literal(node.id, name) { return found } }
            }
            return nil
        }
        let ordered = nodeList
        // A sampler takes conditioning or a guider (KSamplerSelect only picks a sampler name).
        if let sampler = ordered.first(where: { node in
            let all = inputs(of: node.id)
            return (node.classType.hasPrefix("KSampler") || node.classType.hasPrefix("SamplerCustom"))
                && (all["positive"] != nil || all["guider"] != nil)
        })?.id {
            let samplerInputs = inputs(of: sampler)
            let guider = linkedNode(samplerInputs["guider"]).map { inputs(of: $0) } ?? [:]
            add(.seed, literal(sampler, "seed") ?? literal(sampler, "noise_seed")
                ?? linkedNode(samplerInputs["noise"]).flatMap { literal($0, "noise_seed") ?? literal($0, "seed") })
            add(.steps, literal(sampler, "steps") ?? linkedNode(samplerInputs["sigmas"]).flatMap { literal($0, "steps") })
            add(.denoise, literal(sampler, "denoise") ?? linkedNode(samplerInputs["sigmas"]).flatMap { literal($0, "denoise") })
            add(.prompt, traceText(from: samplerInputs["positive"] ?? guider["positive"] ?? guider["conditioning"], branch: "positive"))
            add(.negativePrompt, traceText(from: samplerInputs["negative"] ?? guider["negative"], branch: "negative"))
        }
        if slots.first(where: { $0.kind == .prompt }) == nil {
            // TTS and other text-driven nodes: prefer a text encoder, else any text/prompt input.
            add(.prompt, firstLiteral(["text", "prompt"], where: { $0.contains("TextEncode") }) ?? firstLiteral(["text", "prompt"]))
        }
        if slots.first(where: { $0.kind == .prompt }) == nil {
            // Text routed through switches or string tools: the user's text box is the multiline primitive.
            add(.prompt, firstLiteral(["value"], where: { $0 == "PrimitiveStringMultiline" }) ?? firstLiteral(["value"], where: { $0.hasPrefix("PrimitiveString") }))
        }
        add(.seed, firstLiteral(["seed", "noise_seed"]))
        add(.steps, firstLiteral(["steps"]))
        if let sized = ordered.first(where: { node in
            let all = inputs(of: node.id)
            return all["width"] != nil && all["height"] != nil && (node.classType.contains("Latent") || node.classType.contains("Video"))
        })?.id {
            add(.width, literal(sized, "width"))
            add(.height, literal(sized, "height"))
        }
        add(.seconds, firstLiteral(["seconds"]))
        add(.frames, firstLiteral(["length", "video_frames", "num_frames", "frames"]))
        add(.fps, firstLiteral(["fps", "frame_rate"]))
        let loaders = ordered.filter { $0.classType == "LoadImage" }.map(\.id)
        // A second LoadImage is a mask only when its MASK output (slot 1) or an ImageToMask uses it;
        // otherwise it is another reference image (e.g. Flux2 multi-reference edits).
        func feedsMask(_ loader: String) -> Bool {
            nodes.contains { _, node in
                let isImageToMask = (node["class_type"] as? String)?.contains("ToMask") == true
                return (node["inputs"] as? [String: Any] ?? [:]).values.contains { value in
                    guard let link = value as? [Any], link.first as? String == loader else { return false }
                    return (link.last as? NSNumber)?.intValue == 1 || isImageToMask
                }
            }
        }
        let maskLoader = ordered.first(where: { $0.classType == "LoadImageMask" })?.id
            ?? loaders.dropFirst().first(where: feedsMask)
        if let image = loaders.first(where: { $0 != maskLoader }) { slots.append(.init(kind: .image, node: image, input: "image")) }
        if let maskLoader { slots.append(.init(kind: .mask, node: maskLoader, input: "image")) }
        let audioLoader = ordered.first { $0.classType == "LoadAudio" }?.id
        if let audioLoader { slots.append(.init(kind: .audio, node: audioLoader, input: "audio")) }
        let videoLoader = ordered.first { $0.classType == "LoadVideo" || $0.classType == "VHS_LoadVideo" }
        if let videoLoader {
            slots.append(.init(kind: .video, node: videoLoader.id, input: scalarInputs(of: videoLoader.id).contains("file") ? "file" : "video"))
        }

        let isVideoOutput = { (type: String) in
            ["SaveVideo", "SaveWEBM", "SaveAnimated", "VHS_VideoCombine"].contains { type.hasPrefix($0) }
        }
        let isAudioOutput = { (type: String) in type.hasPrefix("SaveAudio") || type == "PreviewAudio" }
        let is3DOutput = { (type: String) in type == "SaveGLB" || type.hasPrefix("Save3D") || type == "Preview3D" }
        let output: String?
        let capability: Capability
        if let mesh = ordered.first(where: { is3DOutput($0.classType) })?.id {
            output = mesh
            capability = .model3DCreate
        } else if let video = ordered.first(where: { isVideoOutput($0.classType) })?.id {
            output = video
            capability = videoLoader != nil ? .videoEdit : .videoCreate
        } else if let audio = ordered.first(where: { isAudioOutput($0.classType) })?.id {
            output = audio
            capability = audioLoader != nil ? .audioEdit : .audioCreate
        } else {
            output = ordered.first { $0.classType == "SaveImage" }?.id ?? ordered.first { $0.classType == "PreviewImage" }?.id
            capability = loaders.isEmpty ? .imageCreate : .imageEdit
        }
        return (slots, output, capability)
    }

    /// Follows conditioning links up to the text that feeds them (a literal or a primitive).
    private func traceText(from link: Any?, branch: String, depth: Int = 0) -> TemplateSlot? {
        guard depth < 6, let node = linkedNode(link) else { return nil }
        let nodeInputs = inputs(of: node)
        for key in ["text", "prompt"] where nodeInputs[key] != nil {
            if let found = literal(node, key) { return found }
        }
        for key in [branch, "conditioning", "conditioning_1", "conditioning_to"] {
            if let found = traceText(from: nodeInputs[key], branch: branch, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The runnable graph with slot values written in.
    public func filled(_ values: [TemplateSlot: any Sendable]) throws -> Data {
        var nodes = self.nodes
        for (slot, value) in values {
            guard var node = nodes[slot.node], var inputs = node["inputs"] as? [String: Any] else {
                throw ConfigurationError.invalid("Template slot points to missing node \(slot.node)")
            }
            inputs[slot.input] = value
            node["inputs"] = inputs
            nodes[slot.node] = node
        }
        return try JSONSerialization.data(withJSONObject: nodes)
    }
}
