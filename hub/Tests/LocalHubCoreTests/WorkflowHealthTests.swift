import CoreFoundation
import Foundation
import XCTest
@testable import LocalHubCore

final class WorkflowHealthTests: XCTestCase {
    private func fixture(_ name: String = "sdxl-text-to-image.json") throws -> (WorkflowTemplate, [String: Any]) {
        let json = try sample(name), detected = try WorkflowGraph(json: json).detectSlots()
        let template = WorkflowTemplate(id: "health", name: "Health", integrationID: "comfyui", capability: detected.capability,
            workflow: json, slots: detected.slots, outputNode: detected.outputNode)
        let nodes = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: [String: Any]]
        var catalog: [String: Any] = [:]
        for node in nodes.values {
            let type = node["class_type"] as! String
            var required: [String: Any] = [:]
            for (name, value) in node["inputs"] as! [String: Any] {
                if name == "ckpt_name" { required[name] = [[value]] as [Any] }
                else if value is String { required[name] = ["STRING", [:]] as [Any] }
                else if let number = value as? NSNumber {
                    required[name] = [CFGetTypeID(number) == CFBooleanGetTypeID() ? "BOOLEAN" : number.doubleValue.rounded() == number.doubleValue ? "INT" : "FLOAT", [:]] as [Any]
                } else { required[name] = ["ANY", [:]] as [Any] }
            }
            catalog[type] = ["input": ["required": required], "output": ["ANY", "ANY", "ANY", "ANY"], "output_node": type == "SaveImage"]
        }
        return (template, catalog)
    }

    func testValidGraphPassesCatalogChecksWithoutClaimingExecutionWasTested() throws {
        let (template, info) = try fixture()
        let report = WorkflowInspector.inspect(template, objectInfo: info, device: "mps")
        XCTAssertFalse(report.hasErrors, "\(report.findings)")
        XCTAssertTrue(report.findings.contains { $0.id == "runtime" && $0.status == .info })
        XCTAssertEqual(report.workflowVersion, try JobRecipe.version(of: template))
    }

    func testMissingNodeAndModelAreActionableFailures() throws {
        let (template, info) = try fixture()
        var missingNode = info; missingNode.removeValue(forKey: "KSampler")
        let missing = WorkflowInspector.inspect(template, objectInfo: missingNode, device: "mps")
        XCTAssertTrue(missing.findings.contains { $0.title.contains("Missing node") && $0.status == .failed })
        var missingModel = info
        missingModel["CheckpointLoaderSimple"] = ["input": ["required": ["ckpt_name": [["other-model.safetensors"]]]], "output": ["MODEL", "CLIP", "VAE"]]
        let modelReport = WorkflowInspector.inspect(template, objectInfo: missingModel, device: "mps")
        XCTAssertTrue(modelReport.findings.contains { $0.title == "Unavailable model or option" && $0.status == .failed })
    }

    func testBrokenConnectionsWrongScalarTypesAndDuplicateSlotsFail() throws {
        var (template, info) = try fixture()
        var graph = try JSONSerialization.jsonObject(with: Data(template.workflow.utf8)) as! [String: [String: Any]]
        var sampler = graph["3"]!, inputs = sampler["inputs"] as! [String: Any]
        inputs["seed"] = "not a number"; inputs["model"] = ["missing-node", 0] as [Any]
        sampler["inputs"] = inputs; graph["3"] = sampler
        template.workflow = String(decoding: try JSONSerialization.data(withJSONObject: graph), as: UTF8.self)
        template.slots.append(template.slots.first!)
        let report = WorkflowInspector.inspect(template, objectInfo: info, device: "mps")
        XCTAssertTrue(report.findings.contains { $0.id == "duplicate-slots" })
        XCTAssertTrue(report.findings.contains { $0.title == "Broken node connection" })
        XCTAssertTrue(report.findings.contains { $0.title == "Invalid input type" })
    }

    func testMappedUploadDoesNotRequireAnAlreadyInstalledImage() throws {
        let (template, original) = try fixture("sdxl-inpaint.json")
        var info = original
        for type in ["LoadImage", "LoadImageMask"] where info[type] != nil {
            var node = info[type] as! [String: Any]
            var input = node["input"] as! [String: Any]
            var required = input["required"] as! [String: Any]
            required["image"] = [["some-other-image.png"]]
            input["required"] = required; node["input"] = input; info[type] = node
        }
        let report = WorkflowInspector.inspect(template, objectInfo: info, device: "mps")
        XCTAssertFalse(report.hasErrors, "\(report.findings)")
    }

    func testOutputAndPrecisionConflictsFailAndUnknownDeviceWarns() throws {
        var (template, info) = try fixture()
        let unknown = WorkflowInspector.inspect(template, objectInfo: info, device: nil)
        XCTAssertTrue(unknown.findings.contains { $0.id == "device" && $0.status == .warning })
        template.workflow = template.workflow.replacingOccurrences(of: ".safetensors", with: "-fp8.safetensors")
        var output = info["SaveImage"] as! [String: Any]; output["output_node"] = false; info["SaveImage"] = output
        let report = WorkflowInspector.inspect(template, objectInfo: info, device: "mps")
        XCTAssertTrue(report.findings.contains { $0.id == "device" && $0.status == .failed })
        XCTAssertTrue(report.findings.contains { $0.id == "output" && $0.status == .failed })
    }

    func testEmptyModelCatalogAndIncorrectSlotTypesFail() throws {
        var (template, info) = try fixture()
        info["CheckpointLoaderSimple"] = ["input": ["required": ["ckpt_name": [[]] as [Any]]], "output": ["MODEL", "CLIP", "VAE"]]
        template.slots.removeAll { $0.kind == .prompt }
        template.slots.append(TemplateSlot(kind: .prompt, node: "3", input: "steps"))
        let report = WorkflowInspector.inspect(template, objectInfo: info, device: "mps")
        XCTAssertTrue(report.findings.contains { $0.title == "Unavailable model or option" })
        XCTAssertTrue(report.findings.contains { $0.title == "Incompatible request mapping" })
    }
}
