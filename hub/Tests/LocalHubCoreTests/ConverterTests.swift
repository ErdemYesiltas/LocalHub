import Foundation
import XCTest
@testable import LocalHubCore

/// A slice of ComfyUI's `/object_info`, enough for the fixtures below.
nonisolated(unsafe) private let objectInfo: [String: Any] = {
    func node(_ required: [(String, [Any])], optional: [(String, [Any])] = []) -> [String: Any] {
        ["input": ["required": Dictionary(uniqueKeysWithValues: required), "optional": Dictionary(uniqueKeysWithValues: optional)],
         "input_order": ["required": required.map(\.0), "optional": optional.map(\.0)]]
    }
    return [
        "CheckpointLoaderSimple": node([("ckpt_name", [["a.safetensors"]])]),
        "CLIPTextEncode": node([("text", ["STRING", ["multiline": true]]), ("clip", ["CLIP"])]),
        "EmptyLatentImage": node([("width", ["INT"]), ("height", ["INT"]), ("batch_size", ["INT"])]),
        "KSampler": node([("model", ["MODEL"]), ("seed", ["INT", ["control_after_generate": true]]), ("steps", ["INT"]),
                          ("cfg", ["FLOAT"]), ("sampler_name", [["euler"]]), ("scheduler", [["normal"]]),
                          ("positive", ["CONDITIONING"]), ("negative", ["CONDITIONING"]), ("latent_image", ["LATENT"]),
                          ("denoise", ["FLOAT"])]),
        "VAEDecode": node([("samples", ["LATENT"]), ("vae", ["VAE"])]),
        "ImageScale": node([("image", ["IMAGE"]), ("upscale_method", [["nearest"]]), ("width", ["INT"]), ("height", ["INT"]), ("crop", [["disabled"]])]),
        "SaveImage": node([("images", ["IMAGE"]), ("filename_prefix", ["STRING"])]),
        "SaveVideo": node([("video", ["VIDEO"]), ("filename_prefix", ["STRING"]), ("format", ["COMFY_DYNAMICCOMBO_V3"])]),
        "PrimitiveStringMultiline": node([("value", ["STRING"])]),
    ]
}()

private func convert(_ json: String) throws -> [String: [String: Any]] {
    var converter = ComfyUIConverter(objectInfo: objectInfo)
    let api = try converter.convert(json)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(api.utf8)) as? [String: [String: Any]])
}

private func inputs(_ graph: [String: [String: Any]], _ id: String) -> [String: Any] {
    graph[id]?["inputs"] as? [String: Any] ?? [:]
}

final class ConverterTests: XCTestCase {
    /// Positional widgets (older files), a reroute, a frontend primitive, a bypassed and a muted node, a note.
    func testClassicWorkflow() throws {
        let workflow = #"""
        {"nodes": [
          {"id": 4, "type": "CheckpointLoaderSimple", "mode": 0, "widgets_values": ["a.safetensors"], "inputs": []},
          {"id": 6, "type": "CLIPTextEncode", "mode": 0, "widgets_values": ["a fox"], "inputs": [{"name": "clip", "type": "CLIP", "link": 1}]},
          {"id": 20, "type": "Reroute", "mode": 0, "inputs": [{"name": "", "type": "*", "link": 2}]},
          {"id": 7, "type": "CLIPTextEncode", "mode": 0, "widgets_values": ["blurry"], "inputs": [{"name": "clip", "type": "CLIP", "link": 3}]},
          {"id": 21, "type": "PrimitiveNode", "mode": 0, "widgets_values": [640, "fixed"], "inputs": []},
          {"id": 5, "type": "EmptyLatentImage", "mode": 0, "widgets_values": [512, 768, 1],
           "inputs": [{"name": "width", "type": "INT", "widget": {"name": "width"}, "link": 4}]},
          {"id": 3, "type": "KSampler", "mode": 0, "widgets_values": [42, "randomize", 20, 7, "euler", "normal", 1],
           "inputs": [{"name": "model", "type": "MODEL", "link": 5}, {"name": "positive", "type": "CONDITIONING", "link": 6},
                      {"name": "negative", "type": "CONDITIONING", "link": 7}, {"name": "latent_image", "type": "LATENT", "link": 8}]},
          {"id": 8, "type": "VAEDecode", "mode": 0, "inputs": [{"name": "samples", "type": "LATENT", "link": 9}, {"name": "vae", "type": "VAE", "link": 10}]},
          {"id": 30, "type": "ImageScale", "mode": 4, "widgets_values": ["nearest", 1024, 1024, "disabled"], "inputs": [{"name": "image", "type": "IMAGE", "link": 11}]},
          {"id": 9, "type": "SaveImage", "mode": 0, "widgets_values": ["out"], "inputs": [{"name": "images", "type": "IMAGE", "link": 12}]},
          {"id": 11, "type": "SaveImage", "mode": 2, "widgets_values": ["muted"], "inputs": [{"name": "images", "type": "IMAGE", "link": 13}]},
          {"id": 10, "type": "Note", "mode": 0, "widgets_values": ["hello"]}
        ], "links": [
          [1, 4, 1, 6, 0, "CLIP"], [2, 4, 1, 20, 0, "CLIP"], [3, 20, 0, 7, 0, "CLIP"], [4, 21, 0, 5, 0, "INT"],
          [5, 4, 0, 3, 0, "MODEL"], [6, 6, 0, 3, 4, "CONDITIONING"], [7, 7, 0, 3, 5, "CONDITIONING"], [8, 5, 0, 3, 6, "LATENT"],
          [9, 3, 0, 8, 0, "LATENT"], [10, 4, 2, 8, 1, "VAE"], [11, 8, 0, 30, 0, "IMAGE"], [12, 30, 0, 9, 0, "IMAGE"], [13, 8, 0, 11, 0, "IMAGE"]
        ]}
        """#
        let graph = try convert(workflow)
        XCTAssertEqual(Set(graph.keys), ["3", "4", "5", "6", "7", "8", "9"], "reroute, primitive, bypassed, muted and note nodes drop out")
        let sampler = inputs(graph, "3")
        XCTAssertEqual(sampler["seed"] as? Int, 42)
        XCTAssertEqual(sampler["steps"] as? Int, 20, "the seed's control value (randomize) is skipped")
        XCTAssertEqual(sampler["sampler_name"] as? String, "euler")
        XCTAssertEqual(sampler["negative"] as? [AnyHashable], ["7", 0], "followed through the reroute")
        XCTAssertEqual(inputs(graph, "5")["width"] as? Int, 640, "frontend primitive becomes a literal")
        XCTAssertEqual(inputs(graph, "5")["height"] as? Int, 768)
        XCTAssertEqual(inputs(graph, "9")["images"] as? [AnyHashable], ["8", 0], "bypassed node passes its input through")
        XCTAssertEqual(graph["3"]?["class_type"] as? String, "KSampler")
    }

    /// Named widgets, a subgraph fed by a top-level primitive and a promoted widget, dotted dynamic-combo keys, text numbers.
    func testSubgraphsAndNamedWidgets() throws {
        let workflow = #"""
        {"nodes": [
          {"id": 1, "type": "PrimitiveStringMultiline", "mode": 0, "widgets_values_named": {"value": "a paper boat"}, "inputs": []},
          {"id": 2, "type": "sg-1", "mode": 0, "widgets_values_named": {"steps": "12"},
           "inputs": [{"name": "text", "type": "STRING", "widget": {"name": "text"}, "link": 1},
                      {"name": "steps", "type": "INT", "widget": {"name": "steps"}, "link": null}]},
          {"id": 3, "type": "SaveImage", "mode": 0, "widgets_values_named": {"filename_prefix": "boat"}, "inputs": [{"name": "images", "type": "IMAGE", "link": 2}]},
          {"id": 4, "type": "SaveVideo", "mode": 0, "widgets_values_named": {"filename_prefix": "v", "format": "auto", "format.codec": "h264", "codec": "stale"}, "inputs": []}
        ],
        "links": [[1, 1, 0, 2, 0, "STRING"], [2, 2, 0, 3, 0, "IMAGE"]],
        "definitions": {"subgraphs": [{
          "id": "sg-1",
          "inputs": [{"name": "text", "type": "STRING", "linkIds": [10]}, {"name": "steps", "type": "INT", "linkIds": [11]}],
          "outputs": [{"name": "IMAGE", "type": "IMAGE", "linkIds": [12]}],
          "nodes": [
            {"id": 5, "type": "CLIPTextEncode", "mode": 0, "widgets_values_named": {"text": ""},
             "inputs": [{"name": "text", "type": "STRING", "widget": {"name": "text"}, "link": 10}]},
            {"id": 6, "type": "KSampler", "mode": 0,
             "widgets_values_named": {"seed": 7, "control_after_generate": "fixed", "steps": 30, "cfg": 5, "sampler_name": "euler", "scheduler": "normal", "denoise": 1},
             "inputs": [{"name": "positive", "type": "CONDITIONING", "link": 13}, {"name": "steps", "type": "INT", "widget": {"name": "steps"}, "link": 11}]},
            {"id": 7, "type": "VAEDecode", "mode": 0, "inputs": [{"name": "samples", "type": "LATENT", "link": 14}]}
          ],
          "links": [
            {"id": 10, "origin_id": -10, "origin_slot": 0, "target_id": 5, "target_slot": 0, "type": "STRING"},
            {"id": 11, "origin_id": -10, "origin_slot": 1, "target_id": 6, "target_slot": 1, "type": "INT"},
            {"id": 12, "origin_id": 7, "origin_slot": 0, "target_id": -20, "target_slot": 0, "type": "IMAGE"},
            {"id": 13, "origin_id": 5, "origin_slot": 0, "target_id": 6, "target_slot": 0, "type": "CONDITIONING"},
            {"id": 14, "origin_id": 6, "origin_slot": 0, "target_id": 7, "target_slot": 0, "type": "LATENT"}
          ]
        }]}}
        """#
        let graph = try convert(workflow)
        XCTAssertEqual(Set(graph.keys), ["1", "2:5", "2:6", "2:7", "3", "4"], "subgraph nodes are flattened as outer:inner")
        XCTAssertEqual(inputs(graph, "2:5")["text"] as? [AnyHashable], ["1", 0], "subgraph input wired from the parent graph")
        XCTAssertEqual(inputs(graph, "2:6")["steps"] as? Int, 12, "promoted widget value, coerced from text")
        XCTAssertNil(inputs(graph, "2:6")["control_after_generate"], "frontend-only keys are dropped")
        XCTAssertEqual(inputs(graph, "3")["images"] as? [AnyHashable], ["2:7", 0], "subgraph output resolved to the inner node")
        XCTAssertEqual(inputs(graph, "4")["format.codec"] as? String, "h264", "dynamic-combo sub-inputs keep their dotted keys")
        XCTAssertNil(inputs(graph, "4")["codec"], "keys the node does not declare are dropped")

        let detected = try WorkflowGraph(json: String(decoding: JSONSerialization.data(withJSONObject: graph), as: UTF8.self)).detectSlots()
        XCTAssertTrue(detected.slots.contains(.init(kind: .prompt, node: "1", input: "value")), "the prompt is the primitive feeding the encoder: \(detected.slots)")
    }

    func testMissingNodesAndAPIFilesAreReported() throws {
        XCTAssertThrowsError(try convert(#"{"nodes": [{"id": 1, "type": "SomeCustomNode", "mode": 0}], "links": []}"#)) { error in
            XCTAssertTrue("\(error)".contains("SomeCustomNode"))
        }
        let api = #"{"1": {"class_type": "SaveImage", "inputs": {"filename_prefix": "x"}}}"#
        var converter = ComfyUIConverter(objectInfo: objectInfo)
        XCTAssertEqual(try converter.convert(api), api, "API-format files pass through")
    }

    func testSecondLoadImageIsAMaskOnlyWhenUsedAsOne() throws {
        let reference = #"""
        {"1": {"class_type": "LoadImage", "inputs": {"image": "a.png"}},
         "2": {"class_type": "LoadImage", "inputs": {"image": "b.png"}},
         "3": {"class_type": "CLIPTextEncode", "inputs": {"text": "x", "clip": ["9", 0]}},
         "4": {"class_type": "SaveImage", "inputs": {"images": ["1", 0], "filename_prefix": "x"}}}
        """#
        XCTAssertNil(try WorkflowGraph(json: reference).detectSlots().slots.first { $0.kind == .mask }, "a second reference image is not a mask")
        let masked = reference.replacingOccurrences(of: #""4": {"#, with: #""5": {"class_type": "SetLatentNoiseMask", "inputs": {"mask": ["2", 1], "samples": ["9", 0]}}, "4": {"#)
        XCTAssertEqual(try WorkflowGraph(json: masked).detectSlots().slots.first { $0.kind == .mask }?.node, "2")
    }
}
