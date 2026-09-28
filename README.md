# LongCat-Video-Avatar 1.5 — RunPod serverless worker

Lip-sync avatar (photo + audio → talking video) as a scale-to-zero RunPod serverless
endpoint, same shape as the project's existing `ltx25-i2v` endpoint (see `~/kid/ai-video/CLAUDE.md`
section 4 for why this exists and the cost/quality verdict).

Built on `runpod-workers/worker-comfyui` (official RunPod ComfyUI worker) +
[Kijai's ComfyUI-WanVideoWrapper](https://github.com/kijai/ComfyUI-WanVideoWrapper), the
only known way to run LongCat Avatar on a single GPU without the native `torchrun`
pipeline's 2-GPU assumption.

## What's baked into the image (~26GB, no network volume — same cold-start tradeoff as ltx25-i2v)

| File | Folder | Size |
|---|---|---|
| `LongCat-Avatar-single_fp8_e4m3fn_scaled_mixed_KJ.safetensors` | `models/diffusion_models/` | ~17GB |
| `MelBandRoformer_fp32.safetensors` (vocal separation) | `models/diffusion_models/` | ~0.9GB |
| `Wan2_1_VAE_bf16.safetensors` | `models/vae/` | ~0.25GB |
| `umt5-xxl-enc-fp8_e4m3fn.safetensors` (text encoder) | `models/text_encoders/` | ~6.7GB |
| `LongCat_distill_lora_alpha64_bf16.safetensors` | `models/loras/` | ~1.3GB |
| `wav2vec2-chinese-base_fp16.safetensors` | `models/wav2vec2/` | ~0.2GB |

## workflow_api.json

Converted from Kijai's own official example
(`example_workflows/LongCatAvatar_audio_image_to_video_example_01.json` in
ComfyUI-WanVideoWrapper) — UI format → API format, done via a real ComfyUI instance
(Playwright driving `window.app.loadGraphData()` + `window.app.graphToPrompt()`, not a
blind hand conversion) so every node resolves correctly. See `convert.mjs`.

Patches applied vs the raw export:
- `138.inputs.lora`: workflow referenced `LongCat_distill_lora_rank128_bf16.safetensors`,
  which doesn't exist in the model repo — fixed to `LongCat_distill_lora_alpha64_bf16.safetensors`.
- `122.inputs.attention_mode`: `sageattn` → `sdpa` (avoids needing a compiled SageAttention
  extension in the image; pytorch-native, always available).
- `241.inputs.model_name` / `quantization`: bf16 text encoder → fp8 (saves ~4.6GB cold start).

Input nodes to patch per-request (same pattern as `scratch/wf.json` for LTX, but this is a
separate tool, not reusing LTX's endpoint):
- `284` (`LoadImage`) — source portrait, swap `.inputs.image` filename, send bytes via `images[]`.
- `125` (`LoadAudio`) — source audio, swap `.inputs.audio` filename, send bytes via `images[]`
  (the worker's `/upload/image` pass-through doesn't check file content against the declared
  type, so audio rides the same channel — same trick as the LTX endpoint, but that's a ComfyUI
  upload-endpoint property, not something copied from LTX).
- `241` (`WanVideoTextEncodeCached`) — `positive_prompt` / `negative_prompt`, describes avatar
  behavior/scene (see CLAUDE.md 7a prompt-quality notes — same idea, different node).

## handler.py

Forked from `runpod-workers/worker-comfyui`'s own `handler.py`, one patch: the stock handler
only collects node outputs under the `"images"` key. `VHS_VideoCombine` (this workflow's video
export node) reports its output under `"gifs"` (misleading key name — it's the mp4, not a gif;
that's VideoHelperSuite's own convention). Unpatched, a finished job would silently return
nothing. Patch mirrors the existing image-handling block: same `/view` endpoint, same
base64/S3 output shape, just reading `"gifs"` instead of `"images"`.

## Status (2026-09-28)

R&D done: workflow converted and verified (all 45 nodes resolve, zero `None` class_types),
model URLs verified against the actual HF repos, Dockerfile written, handler patched.
**Not yet done: image build, Hub deploy, first real test job.** Build takes ~26GB of model
downloads at build time (RunPod Hub builds it, not billed like a running pod) — first test
job cold start will be the first real money spent on this path.
