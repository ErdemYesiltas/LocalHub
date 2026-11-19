# Sample workflows

ComfyUI workflows in **API format** (Workflow › Export (API)) that import into LocalHub › Workflows as-is.
The SDXL ones use `sd_xl_base_1.0.safetensors`; the video one uses Wan 2.2 TI2V 5B
(`wan2.2_ti2v_5B_fp16`, `umt5_xxl_fp8_e4m3fn_scaled`, `wan2.2_vae`).

| File | Capability | Detected slots |
|---|---|---|
| `sdxl-text-to-image.json` | `image.create` | prompt, negative prompt, seed, steps, denoise, width, height |
| `sdxl-inpaint.json` | `image.edit` | prompt, negative prompt, seed, steps, denoise, image, mask |
| `wan22-5b-text-to-video.json` | `video.create` | prompt, negative prompt, seed, steps, denoise, width, height, frames, fps |

For video, a request's `seconds` becomes frames using the workflow's frame rate (Wan adds the extra first frame).

Mask semantics follow OpenAI: transparent pixels are the area to repaint. `LoadImageMask` with channel `alpha`
inverts alpha, so a mask PNG (or the image's own alpha when no mask is sent) works unchanged.
