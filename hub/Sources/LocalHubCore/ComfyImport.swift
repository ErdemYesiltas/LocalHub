import Foundation

/// Turns a ComfyUI **UI** workflow (what Workflow › Save writes: `nodes`, `links`,
/// optional `definitions.subgraphs`) into the **API** graph `/prompt` runs, the way
/// ComfyUI's frontend does: subgraphs are flattened to `outer:inner` ids, bypassed
/// nodes pass their input through, muted nodes and notes drop out, reroutes and
/// frontend primitives are resolved.
public struct ComfyUIConverter {
    private let classes: [String: Any]
    private var subgraphs: [String: [String: Any]] = [:]
    static let virtualTypes: Set<String> = ["Note", "MarkdownNote", "Reroute", "PrimitiveNode"]
    static let controlValues: Set<String> = ["fixed", "increment", "decrement", "randomize"]

    /// `objectInfo` is ComfyUI's `/object_info`.
    public init(objectInfo: [String: Any]) { classes = objectInfo }

    private struct Link { let origin: Int; let originSlot: Int; let target: Int; let targetSlot: Int; let type: String }

    private final class Scope {
        let nodes: [Int: [String: Any]]
        let links: [Int: Link]
        let prefix: String
        let parent: (scope: Scope, instance: [String: Any])?
        let definition: [String: Any]?
        init(nodes: [[String: Any]], links: [Link], linkIDs: [Int], prefix: String,
             parent: (scope: Scope, instance: [String: Any])?, definition: [String: Any]?) {
            self.nodes = Dictionary(nodes.compactMap { node in (node["id"] as? Int).map { ($0, node) } }, uniquingKeysWith: { a, _ in a })
            self.links = Dictionary(zip(linkIDs, links).map { ($0, $1) }, uniquingKeysWith: { a, _ in a })
            self.prefix = prefix; self.parent = parent; self.definition = definition
        }
    }

    private enum Source { case node(String, Int), literal(Any) }

    public mutating func convert(_ json: String) throws -> String {
        guard let workflow = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw ConfigurationError.invalid("The workflow is not JSON")
        }
        guard let nodes = workflow["nodes"] as? [[String: Any]] else {
            // Already API format.
            _ = try WorkflowGraph(json: json)
            return json
        }
        for definition in (workflow["definitions"] as? [String: Any])?["subgraphs"] as? [[String: Any]] ?? [] {
            if let id = definition["id"] as? String { subgraphs[id] = definition }
        }
        let (links, ids) = Self.parseLinks(workflow["links"])
        let top = Scope(nodes: nodes, links: links, linkIDs: ids, prefix: "", parent: nil, definition: nil)
        var graph: [String: Any] = [:]
        try emit(top, into: &graph, depth: 0)
        guard !graph.isEmpty else { throw ConfigurationError.invalid("The workflow has no runnable nodes") }
        return String(decoding: try JSONSerialization.data(withJSONObject: graph, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func parseLinks(_ value: Any?) -> ([Link], [Int]) {
        var links: [Link] = [], ids: [Int] = []
        for item in value as? [Any] ?? [] {
            if let array = item as? [Any], array.count >= 6, let id = array[0] as? Int, let origin = array[1] as? Int,
               let originSlot = array[2] as? Int, let target = array[3] as? Int, let targetSlot = array[4] as? Int {
                links.append(Link(origin: origin, originSlot: originSlot, target: target, targetSlot: targetSlot, type: "\(array[5])"))
                ids.append(id)
            } else if let object = item as? [String: Any], let id = object["id"] as? Int, let origin = object["origin_id"] as? Int,
                      let originSlot = object["origin_slot"] as? Int, let target = object["target_id"] as? Int,
                      let targetSlot = object["target_slot"] as? Int {
                links.append(Link(origin: origin, originSlot: originSlot, target: target, targetSlot: targetSlot, type: "\(object["type"] ?? "")"))
                ids.append(id)
            }
        }
        return (links, ids)
    }

    private func child(of scope: Scope, instance: [String: Any]) -> Scope? {
        guard let type = instance["type"] as? String, let definition = subgraphs[type], let id = instance["id"] as? Int else { return nil }
        let (links, ids) = Self.parseLinks(definition["links"])
        return Scope(nodes: definition["nodes"] as? [[String: Any]] ?? [], links: links, linkIDs: ids,
            prefix: "\(scope.prefix)\(id):", parent: (scope, instance), definition: definition)
    }

    private static func mode(_ node: [String: Any]) -> Int { node["mode"] as? Int ?? 0 }

    private func emit(_ scope: Scope, into graph: inout [String: Any], depth: Int) throws {
        guard depth < 16 else { throw ConfigurationError.invalid("Subgraphs are nested too deeply") }
        for id in scope.nodes.keys.sorted() {
            let node = scope.nodes[id]!
            let type = node["type"] as? String ?? ""
            guard Self.mode(node) == 0 else { continue }  // 2 = muted, 4 = bypassed
            if let inner = child(of: scope, instance: node) { try emit(inner, into: &graph, depth: depth + 1); continue }
            if Self.virtualTypes.contains(type) { continue }
            guard let info = classes[type] as? [String: Any] else {
                throw ConfigurationError.invalid("Node “\(type)” is not installed in this ComfyUI")
            }
            var inputs = widgetValues(node, info: info)
            for input in node["inputs"] as? [[String: Any]] ?? [] {
                guard let linkID = input["link"] as? Int else { continue }
                let name = (input["widget"] as? [String: Any])?["name"] as? String ?? input["name"] as? String ?? ""
                switch try resolve(scope, link: linkID, depth: 0) {
                case .node(let source, let slot)?: inputs[name] = [source, slot]
                case .literal(let value)?:
                    let spec = info["input"] as? [String: Any]
                    let entry = (spec?["required"] as? [String: Any])?[name] ?? (spec?["optional"] as? [String: Any])?[name]
                    inputs[name] = (entry as? [Any]).map { Self.coerce(value, to: $0) } ?? value
                case nil: break
                }
            }
            var entry: [String: Any] = ["class_type": type, "inputs": inputs]
            if let title = node["title"] as? String { entry["_meta"] = ["title": title] }
            graph["\(scope.prefix)\(id)"] = entry
        }
    }

    /// Literal widget values: by name when the file has `widgets_values_named`, else in `input_order`.
    private func widgetValues(_ node: [String: Any], info: [String: Any]) -> [String: Any] {
        let spec = info["input"] as? [String: Any] ?? [:]
        let required = spec["required"] as? [String: Any] ?? [:]
        let optional = spec["optional"] as? [String: Any] ?? [:]
        let known = required.merging(optional) { a, _ in a }
        if let named = (node["widgets_values_named"] ?? node["widgets_values"]) as? [String: Any] {
            // Dynamic combos store their sub-inputs as `format.codec`; the API expects the same keys.
            var result: [String: Any] = [:]
            for (key, value) in named {
                let root = String(key.split(separator: ".", maxSplits: 1).first ?? "")
                guard let entry = known[root] as? [Any] else { continue }
                result[key] = key == root ? Self.coerce(value, to: entry) : value
            }
            return result
        }
        let order = ((info["input_order"] as? [String: Any])?["required"] as? [String] ?? required.keys.sorted())
            + ((info["input_order"] as? [String: Any])?["optional"] as? [String] ?? optional.keys.sorted())
        let values = node["widgets_values"] as? [Any] ?? []
        var result: [String: Any] = [:]
        var index = 0
        for name in order {
            guard let entry = known[name] as? [Any], Self.isWidget(entry), index < values.count else { continue }
            result[name] = Self.coerce(values[index], to: entry)
            index += 1
            let config = entry.count > 1 ? entry[1] as? [String: Any] : nil
            if config?["control_after_generate"] as? Bool == true || ["seed", "noise_seed"].contains(name),
               index < values.count, let control = values[index] as? String, Self.controlValues.contains(control) {
                index += 1
            }
        }
        return result
    }

    /// Some widgets save numbers as text (`"1536"` for an INT input); the server rejects that.
    private static func coerce(_ value: Any, to entry: [Any]) -> Any {
        guard let text = value as? String else { return value }
        switch entry.first as? String {
        case "INT": return Int(text) ?? value
        case "FLOAT": return Double(text) ?? value
        default: return value
        }
    }

    private static func isWidget(_ entry: [Any]) -> Bool {
        if (entry.count > 1 ? entry[1] as? [String: Any] : nil)?["forceInput"] as? Bool == true { return false }
        if entry.first is [Any] { return true }
        return ["INT", "FLOAT", "STRING", "BOOLEAN", "COMBO"].contains(entry.first as? String ?? "")
    }

    private func resolve(_ scope: Scope, link id: Int, depth: Int) throws -> Source? {
        guard let link = scope.links[id] else { return nil }
        return try resolveOutput(scope, node: link.origin, slot: link.originSlot, type: link.type, depth: depth + 1)
    }

    private func resolveOutput(_ scope: Scope, node id: Int, slot: Int, type: String, depth: Int) throws -> Source? {
        guard depth < 64 else { throw ConfigurationError.invalid("The workflow's links form a loop") }
        if id == -10 {  // a subgraph's input: whatever feeds the instance in the parent graph
            guard let parent = scope.parent,
                  let input = (scope.definition?["inputs"] as? [[String: Any]])?[safe: slot],
                  let name = input["name"] as? String else { return nil }
            let instanceInput = (parent.instance["inputs"] as? [[String: Any]] ?? []).first { $0["name"] as? String == name }
            if let link = instanceInput?["link"] as? Int { return try resolve(parent.scope, link: link, depth: depth) }
            if let value = (parent.instance["widgets_values_named"] as? [String: Any])?[name] { return .literal(value) }
            let widgetNames = (parent.instance["inputs"] as? [[String: Any]] ?? []).filter { $0["widget"] != nil }.compactMap { $0["name"] as? String }
            if let index = widgetNames.firstIndex(of: name), let value = (parent.instance["widgets_values"] as? [Any])?[safe: index] {
                return .literal(value)
            }
            return nil
        }
        guard let node = scope.nodes[id] else { return nil }
        let nodeType = node["type"] as? String ?? ""
        switch Self.mode(node) {
        case 2: return nil
        case 4:  // bypassed: the first input of the same type passes through
            let through = (node["inputs"] as? [[String: Any]] ?? []).first { "\($0["type"] ?? "")" == type && $0["link"] is Int }
            return try (through?["link"] as? Int).flatMap { try resolve(scope, link: $0, depth: depth) }
        default: break
        }
        if let inner = child(of: scope, instance: node) {
            guard let output = (inner.definition?["outputs"] as? [[String: Any]])?[safe: slot] else { return nil }
            let linkIDs = output["linkIds"] as? [Int] ?? []
            guard let link = linkIDs.compactMap({ inner.links[$0] }).first(where: { $0.target == -20 }) else { return nil }
            return try resolveOutput(inner, node: link.origin, slot: link.originSlot, type: type, depth: depth + 1)
        }
        if nodeType == "Reroute" {
            guard let link = (node["inputs"] as? [[String: Any]])?.first?["link"] as? Int else { return nil }
            return try resolve(scope, link: link, depth: depth)
        }
        if nodeType == "PrimitiveNode" {
            return ((node["widgets_values"] as? [Any])?.first).map { .literal($0) }
        }
        return .node("\(scope.prefix)\(id)", slot)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A run from ComfyUI's history: the exact API graph ComfyUI executed.
public struct ComfyRun: Sendable, Identifiable, Equatable {
    public let id: String
    public let createdAt: Date?
    public let summary: String
    /// `image`, `audio` or `video` from what the run saved.
    public let output: String
    public let nodeCount: Int
    public let workflow: String
}

/// Reads workflows from a ComfyUI integration so the app can import them without
/// the user exporting files by hand.
public struct ComfyLibrary: Sendable {
    let upstream: Upstream

    public init(integration: ProviderConfiguration) { upstream = Upstream(provider: integration) }

    /// Names under ComfyUI's `user/default/workflows`, e.g. `sdxl_simple_example.json`.
    public func savedWorkflows() async throws -> [String] {
        let (data, response) = try await upstream.send("GET", "/api/userdata",
            query: [.init(name: "dir", value: "workflows"), .init(name: "recurse", value: "true")])
        guard response.statusCode == 200, let names = (try? JSONSerialization.jsonObject(with: data)) as? [String] else { return [] }
        return names.filter { $0.lowercased().hasSuffix(".json") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A saved workflow converted to the API format.
    public func savedWorkflow(_ name: String) async throws -> String {
        guard !name.isEmpty, name.count <= 200, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
              let encoded = "workflows/\(name)".addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_. "))) else {
            throw ConfigurationError.invalid("Invalid workflow name")
        }
        let (data, response) = try await upstream.send("GET", "/api/userdata/\(encoded.replacingOccurrences(of: " ", with: "%20"))")
        guard response.statusCode == 200 else { throw ConfigurationError.invalid("ComfyUI could not read \(name)") }
        var converter = ComfyUIConverter(objectInfo: try await objectInfo())
        return try converter.convert(String(decoding: data, as: UTF8.self))
    }

    /// The torch device ComfyUI runs on: `mps` on Apple Silicon, `cuda`, `cpu`; `nil` when unreachable.
    public func deviceType() async -> String? {
        guard let (data, response) = try? await upstream.send("GET", "/system_stats", timeout: 5), response.statusCode == 200,
              let devices = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["devices"] as? [[String: Any]] else { return nil }
        return devices.first?["type"] as? String
    }

    public func objectInfo(timeout: TimeInterval = 60) async throws -> [String: Any] {
        let (data, response) = try await upstream.send("GET", "/object_info", timeout: timeout, limit: 256 * 1024 * 1024)
        guard response.statusCode == 200, let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ConfigurationError.invalid("ComfyUI did not return its node list")
        }
        return info
    }

    /// Recent successful runs started from ComfyUI itself or other apps (not LocalHub's own jobs), newest first,
    /// one per distinct graph.
    public func recentRuns(limit: Int = 50) async throws -> [ComfyRun] {
        let (data, response) = try await upstream.send("GET", "/history", query: [.init(name: "max_items", value: "\(limit)")],
            timeout: 30, limit: 256 * 1024 * 1024)
        guard response.statusCode == 200, let history = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var runs: [ComfyRun] = []
        var seen: Set<String> = []
        for (id, value) in history {
            guard let entry = value as? [String: Any], let prompt = entry["prompt"] as? [Any], prompt.count > 2,
                  let graph = prompt[2] as? [String: Any], !graph.isEmpty,
                  (entry["status"] as? [String: Any])?["status_str"] as? String == "success" else { continue }
            let extra = prompt.count > 3 ? prompt[3] as? [String: Any] : nil
            if (extra?["client_id"] as? String)?.hasPrefix("job-") == true { continue }
            let nodes = graph.values.compactMap { $0 as? [String: Any] }
            let classes = nodes.compactMap { $0["class_type"] as? String }
            let outputs = (entry["outputs"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
            let output = outputs.contains { $0["audio"] != nil } ? "audio"
                : outputs.contains { $0["gifs"] != nil || $0["videos"] != nil || $0["animated"] != nil } ? "video" : "image"
            let models = nodes.compactMap { node -> String? in
                let inputs = node["inputs"] as? [String: Any] ?? [:]
                return ["ckpt_name", "unet_name", "model_name"].compactMap { inputs[$0] as? String }.first
            }
            let summary = (models.map { ($0 as NSString).deletingPathExtension } + [classes.contains { $0.hasPrefix("KSampler") } ? "KSampler" : classes.first ?? ""])
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let created = (extra?["create_time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            guard let json = try? JSONSerialization.data(withJSONObject: graph, options: [.sortedKeys]) else { continue }
            runs.append(ComfyRun(id: id, createdAt: created, summary: summary, output: output, nodeCount: nodes.count,
                workflow: String(decoding: json, as: UTF8.self)))
        }
        runs.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        return runs.filter { run in
            let key = (try? WorkflowGraph(json: run.workflow))?.nodeList.map(\.classType).sorted().joined(separator: ",") ?? run.id
            return seen.insert(key).inserted
        }
    }
}
