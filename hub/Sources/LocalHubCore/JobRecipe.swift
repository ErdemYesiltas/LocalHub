import CryptoKit
import Foundation

/// Resolved scalar inputs, including the actual seed chosen before a job starts.
public struct RecipeParameters: Codable, Sendable, Equatable {
    public var prompt: String
    public var negativePrompt: String?
    public var seed: Int?
    public var steps: Int?
    public var width: Int?
    public var height: Int?
    public var denoise: Double?
    public var seconds: Double?
    public var frames: Int?
    public var fps: Double?

    init(template: WorkflowTemplate, request: WorkflowJobRequest) throws {
        let graph = try WorkflowGraph(json: template.workflow)
        func number(_ kind: SlotKind) -> NSNumber? { template.slot(kind).flatMap { graph.value(of: $0) as? NSNumber } }
        prompt = request.prompt
        negativePrompt = template.slot(.negativePrompt) == nil ? nil : request.negativePrompt ?? template.slot(.negativePrompt).flatMap { graph.value(of: $0) as? String }
        seed = template.slot(.seed) == nil ? nil : request.seed ?? Int.random(in: 0...Int(UInt32.max))
        steps = template.slot(.steps) == nil ? nil : request.steps ?? number(.steps)?.intValue
        width = template.slot(.width) == nil ? nil : request.width ?? number(.width)?.intValue
        height = template.slot(.height) == nil ? nil : request.height ?? number(.height)?.intValue
        denoise = template.slot(.denoise) == nil ? nil : request.denoise ?? number(.denoise)?.doubleValue
        seconds = template.slot(.seconds) == nil ? nil : request.seconds ?? number(.seconds)?.doubleValue
        frames = template.slot(.frames) == nil ? nil : request.frames ?? number(.frames)?.intValue
        fps = template.slot(.fps) == nil ? nil : request.fps ?? number(.fps)?.doubleValue
    }

    func request() -> WorkflowJobRequest {
        var result = WorkflowJobRequest(prompt: prompt)
        result.negativePrompt = negativePrompt; result.seed = seed; result.steps = steps
        result.width = width; result.height = height; result.denoise = denoise
        result.seconds = seconds; result.frames = frames; result.fps = fps
        return result
    }
}

public struct RecipeInput: Codable, Sendable, Equatable, Identifiable {
    public var id: SlotKind { kind }
    public let kind: SlotKind
    public let fileID: String
    public let filename: String
    public let sha256: String
}

/// Immutable workflow snapshot and references to retained, device-owned input files.
/// Model *names* are recorded; model binaries and the runtime are not bundled.
public struct JobRecipe: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let template: WorkflowTemplate
    public let workflowVersion: String
    public var parameters: RecipeParameters
    public var inputs: [RecipeInput]
    public var parentJobID: String?
    public let workProfileID: String?
    public let workProfileName: String?
    public let schedule: JobSchedule?
    public let priority: Int?

    public init(template: WorkflowTemplate, request: WorkflowJobRequest, inputs: [RecipeInput] = [], parentJobID: String? = nil) throws {
        schemaVersion = 1
        self.template = template
        workflowVersion = try Self.version(of: template)
        parameters = try RecipeParameters(template: template, request: request)
        self.inputs = inputs
        self.parentJobID = parentJobID
        workProfileID = request.workProfileID; workProfileName = request.workProfileName
        schedule = request.schedule; priority = request.priority
    }

    public static func version(of template: WorkflowTemplate) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(template))
    }

    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    public var modelFiles: [String] {
        guard let graph = try? WorkflowGraph(json: template.workflow) else { return [] }
        let suffixes = [".safetensors", ".sft", ".ckpt", ".pt", ".pth", ".bin", ".gguf"]
        return Array(Set(graph.nodeList.flatMap { node in
            graph.scalarInputs(of: node.id).compactMap { name -> String? in
                guard let value = graph.value(of: TemplateSlot(kind: .prompt, node: node.id, input: name)) as? String,
                      suffixes.contains(where: value.lowercased().hasSuffix) else { return nil }
                return value
            }
        })).sorted()
    }
}

/// Public API projection: does not disclose the private workflow graph.
public struct RecipeSummary: Codable, Sendable {
    public let schemaVersion: Int
    public let workflowName: String
    public let workflowVersion: String
    public let parameters: RecipeParameters
    public let inputs: [RecipeInput]
    public let modelFiles: [String]
    public let parentJobID: String?
    public let workProfileID: String?
    public let workProfileName: String?
    public let schedule: JobSchedule?
    public let priority: Int?

    public init(_ recipe: JobRecipe) {
        schemaVersion = recipe.schemaVersion; workflowName = recipe.template.name
        workflowVersion = recipe.workflowVersion; parameters = recipe.parameters
        inputs = recipe.inputs; modelFiles = recipe.modelFiles; parentJobID = recipe.parentJobID
        workProfileID = recipe.workProfileID; workProfileName = recipe.workProfileName
        schedule = recipe.schedule; priority = recipe.priority
    }
}
