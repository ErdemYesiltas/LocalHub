import Foundation
import CoreFoundation

public enum CheckStatus: String, Codable, Sendable { case passed, warning, failed, info }

public struct HealthFinding: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let status: CheckStatus
    public let detail: String
    public init(_ id: String, _ title: String, _ status: CheckStatus, _ detail: String) {
        self.id = id; self.title = title; self.status = status; self.detail = detail
    }
}

public struct WorkflowHealthReport: Sendable {
    public let workflowVersion: String
    public let checkedAt: Date
    public var findings: [HealthFinding]
    public var hasErrors: Bool { findings.contains { $0.status == .failed } }
    public var warningCount: Int { findings.filter { $0.status == .warning }.count }
}

public enum WorkflowInspector {
    public static func check(_ template: WorkflowTemplate, integration: ProviderConfiguration) async -> WorkflowHealthReport {
        let library = ComfyLibrary(integration: integration)
        do {
            let info = try await library.objectInfo(timeout: 8)
            let device = await library.deviceType()
            var report = inspect(template, objectInfo: info, device: device)
            report.findings.insert(HealthFinding("connection", "ComfyUI connection", .passed, "The node catalog is reachable."), at: 0)
            return report
        } catch {
            return WorkflowHealthReport(workflowVersion: (try? JobRecipe.version(of: template)) ?? "", checkedAt: Date(), findings: [
                HealthFinding("connection", "ComfyUI connection", .failed, "Could not inspect this ComfyUI installation. Start its server and check the integration address."),
                HealthFinding("unchecked", "Installation checks", .info, "Node, model and device compatibility have not been checked.")
            ])
        }
    }

    /// Uses the live object_info catalog without submitting or executing a prompt.
    public static func inspect(_ template: WorkflowTemplate, objectInfo: [String: Any], device: String?) -> WorkflowHealthReport {
        var findings: [HealthFinding] = []
        let version = (try? JobRecipe.version(of: template)) ?? ""
        func finish() -> WorkflowHealthReport { WorkflowHealthReport(workflowVersion: version, checkedAt: Date(), findings: findings) }
        do { try template.validate() }
        catch { findings.append(HealthFinding("structure", "Workflow and input mapping", .failed, error.localizedDescription)); return finish() }
        findings.append(HealthFinding("structure", "Workflow and input mapping", .passed, "Required slots and mapped inputs exist."))
        if Set(template.slots.map(\.kind)).count != template.slots.count {
            findings.append(HealthFinding("duplicate-slots", "Duplicate input mapping", .failed, "Each request value must map to exactly one workflow input."))
        }
        guard let nodes = (try? JSONSerialization.jsonObject(with: Data(template.workflow.utf8))) as? [String: [String: Any]] else { return finish() }
        let mapped = Set(template.slots.map { "\($0.node)/\($0.input)" })
        var installed = 0
        for id in nodes.keys.sorted() {
            let node = nodes[id] ?? [:]
            let type = node["class_type"] as? String ?? "?"
            guard let info = objectInfo[type] as? [String: Any] else {
                findings.append(HealthFinding("node-\(id)", "Missing node: \(type)", .failed, "Install this node in ComfyUI, restart it, then check again. Node #\(id).")); continue
            }
            installed += 1
            let inputs = node["inputs"] as? [String: Any] ?? [:]
            let spec = info["input"] as? [String: Any] ?? [:]
            let required = spec["required"] as? [String: Any] ?? [:]
            let optional = spec["optional"] as? [String: Any] ?? [:]
            for name in required.keys.sorted() where inputs[name] == nil {
                findings.append(HealthFinding("required-\(id)-\(name)", "Missing required input", .failed, "#\(id) \(type) needs “\(name)”. Re-export or repair this workflow."))
            }
            for name in inputs.keys.sorted() {
                let key = "\(id)/\(name)"
                let entry = (required[name] ?? optional[name]) as? [Any] ?? []
                let value = inputs[name]!
                if let link = value as? [Any], link.count == 2, let source = link[0] as? String, let index = link[1] as? Int {
                    guard let sourceNode = nodes[source] else {
                        findings.append(HealthFinding("link-\(key)", "Broken node connection", .failed, "#\(id).\(name) refers to missing node #\(source).")); continue
                    }
                    let sourceType = sourceNode["class_type"] as? String ?? ""
                    if let sourceInfo = objectInfo[sourceType] as? [String: Any], let outputs = sourceInfo["output"] as? [Any],
                       index < 0 || index >= outputs.count {
                        findings.append(HealthFinding("output-\(key)", "Invalid output connection", .failed, "#\(id).\(name) refers to output \(index) of #\(source)."))
                    }
                    continue
                }
                // Image/audio file choices will be replaced by uploads when these slots are mapped.
                if mapped.contains(key), template.slots.contains(where: { $0.node == id && $0.input == name && [.image, .mask, .audio, .video].contains($0.kind) }) { continue }
                let choices = entry.first as? [Any] ?? ((entry.dropFirst().first as? [String: Any])?["options"] as? [Any])
                if let choices {
                    let matches = choices.contains { String(describing: $0) == String(describing: value) }
                    if !matches {
                        findings.append(HealthFinding("choice-\(key)", "Unavailable model or option", .failed,
                            "#\(id) \(type).\(name): “\(value)” is not installed or available. Select an installed option in ComfyUI and re-export."))
                    }
                } else if let expected = entry.first as? String {
                    let valid: Bool
                    switch expected {
                    case "INT": valid = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue } ?? false
                    case "FLOAT": valid = (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite } ?? false
                    case "STRING": valid = value is String
                    case "BOOLEAN": valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                    default: valid = true
                    }
                    if !valid { findings.append(HealthFinding("type-\(key)", "Invalid input type", .failed, "#\(id).\(name) must be \(expected).")) }
                    if let number = value as? NSNumber, let constraints = entry.dropFirst().first as? [String: Any] {
                        let min = (constraints["min"] as? NSNumber)?.doubleValue ?? -.infinity
                        let max = (constraints["max"] as? NSNumber)?.doubleValue ?? .infinity
                        if number.doubleValue < min || number.doubleValue > max {
                            findings.append(HealthFinding("range-\(key)", "Input outside allowed range", .failed, "#\(id).\(name) must be between \(min) and \(max)."))
                        }
                    }
                }
            }
        }
        for slot in template.slots {
            let classType = nodes[slot.node]?["class_type"] as? String ?? ""
            guard let info = objectInfo[classType] as? [String: Any], let spec = info["input"] as? [String: Any] else { continue }
            let entry = ((spec["required"] as? [String: Any])?[slot.input]
                ?? (spec["optional"] as? [String: Any])?[slot.input]) as? [Any] ?? []
            let actual = entry.first is [Any] ? "COMBO" : entry.first as? String ?? "UNKNOWN"
            let allowed: [String]
            switch slot.kind {
            case .prompt, .negativePrompt: allowed = ["STRING"]
            case .seed, .steps, .width, .height, .frames: allowed = ["INT"]
            case .denoise, .seconds, .fps: allowed = ["INT", "FLOAT"]
            case .image, .mask, .audio, .video: allowed = ["COMBO", "STRING"]
            }
            if ["INT", "FLOAT", "STRING", "BOOLEAN", "COMBO"].contains(actual), !allowed.contains(actual) {
                findings.append(HealthFinding("mapping-\(slot.kind.rawValue)", "Incompatible request mapping", .failed,
                    "\(slot.kind.title) maps to #\(slot.node).\(slot.input), which accepts \(actual), not \(allowed.joined(separator: "/"))."))
            } else if actual == "UNKNOWN" {
                findings.append(HealthFinding("mapping-\(slot.kind.rawValue)", "Unverified request mapping", .warning,
                    "The catalog has no type for #\(slot.node).\(slot.input). Run an execution test to verify this mapping."))
            }
        }
        findings.append(HealthFinding("nodes", "Installed nodes", installed == nodes.count ? .passed : .failed, "\(installed) of \(nodes.count) workflow nodes are installed."))
        let outputIDs = nodes.keys.filter { id in
            let type = nodes[id]?["class_type"] as? String ?? ""
            return (objectInfo[type] as? [String: Any])?["output_node"] as? Bool == true
        }
        if let output = template.outputNode {
            findings.append(HealthFinding("output", "Output node", outputIDs.contains(output) ? .passed : .failed,
                outputIDs.contains(output) ? "The selected node produces an output." : "The selected node is not an output node in this installation."))
        } else {
            findings.append(HealthFinding("output", "Output nodes", outputIDs.isEmpty ? .failed : .passed,
                outputIDs.isEmpty ? "No runnable output node was found." : "\(outputIDs.count) output node(s) found."))
        }
        if let warning = template.unsupportedModelWarning(device: device) {
            findings.append(HealthFinding("device", "Model precision", .failed, warning))
        } else if device == nil {
            findings.append(HealthFinding("device", "Device compatibility", .warning, "The compute device could not be identified; precision compatibility is unverified."))
        } else {
            findings.append(HealthFinding("device", "Device compatibility", .passed, "No known precision conflict detected on \(device!)."))
        }
        findings.append(HealthFinding("runtime", "Execution test", .info, "Catalog checks do not execute the graph. Run an explicit test to verify custom-node behavior and output files."))
        return finish()
    }
}
