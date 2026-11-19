import Foundation
import XCTest
@testable import LocalHubCore

/// fp8 weights can't run on ComfyUI's MPS backend: templates warn about them and the failure becomes `model_unsupported`.
final class FP8GuardTests: XCTestCase {
    private func graph(unet: String, dtype: String = "default") -> String {
        #"""
        {"1": {"class_type": "UNETLoader", "inputs": {"unet_name": "\#(unet)", "weight_dtype": "\#(dtype)"}},
         "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen_3_4b.safetensors", "type": "flux2", "device": "default"}},
         "3": {"class_type": "VAELoader", "inputs": {"vae_name": "flux2-vae.safetensors"}},
         "4": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["2", 0], "text": "a fox"}},
         "5": {"class_type": "SaveImage", "inputs": {"filename_prefix": "x", "images": ["6", 0]}},
         "6": {"class_type": "VAEDecode", "inputs": {"samples": ["1", 0], "vae": ["3", 0]}}}
        """#
    }

    func testDetectsFP8ByFileNameOrWeightDtype() throws {
        XCTAssertEqual(try WorkflowGraph(json: graph(unet: "flux-2-klein-4b-fp8.safetensors")).fp8Models, ["flux-2-klein-4b-fp8.safetensors"])
        XCTAssertEqual(try WorkflowGraph(json: graph(unet: "wan2.2_e4m3fn_scaled.safetensors")).fp8Models, ["wan2.2_e4m3fn_scaled.safetensors"])
        XCTAssertEqual(try WorkflowGraph(json: graph(unet: "flux-2-klein-base-4b.safetensors", dtype: "fp8_e4m3fn")).fp8Models,
            ["flux-2-klein-base-4b.safetensors"], "a bf16 file loaded as fp8 fails the same way")
        XCTAssertEqual(try WorkflowGraph(json: graph(unet: "flux-2-klein-base-4b.safetensors")).fp8Models, [], "bf16 and the text encoder/VAE are fine")
    }

    func testWarnsOnlyWhenComfyUIRunsOnMPS() {
        let template = WorkflowTemplate(id: "klein", name: "Klein", integrationID: "comfyui", capability: .imageEdit,
            workflow: graph(unet: "flux-2-klein-4b-fp8.safetensors"), slots: [], outputNode: "5")
        let warning = template.unsupportedModelWarning(device: "mps")
        XCTAssertTrue(warning?.contains("flux-2-klein-4b-fp8.safetensors") == true, "\(warning ?? "nil")")
        XCTAssertTrue(warning?.contains("bf16 or fp16") == true)
        XCTAssertNil(template.unsupportedModelWarning(device: "cuda"))
        XCTAssertNil(template.unsupportedModelWarning(device: nil), "unknown device: no guess")
        var base = template
        base.workflow = graph(unet: "flux-2-klein-base-4b.safetensors")
        XCTAssertNil(base.unsupportedModelWarning(device: "mps"))
    }

    func testRecognisesPyTorchsMPSFloat8Error() {
        XCTAssertTrue(ComfyClient.isFP8OnMPS("Trying to convert Float8_e4m3fn to the MPS backend but it does not have support for that dtype."))
        XCTAssertFalse(ComfyClient.isFP8OnMPS("CUDA out of memory"))
        XCTAssertFalse(ComfyClient.isFP8OnMPS("MPS backend out of memory"))
    }
}
