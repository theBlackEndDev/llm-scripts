# Research — Image/Video model re-exploration (June 2026)

Kicked off by Ideogram 4 (AI Search video, 2026-06-09). Goal: re-pick the
image/video side of the ComfyUI stack now that the box has 62GB RAM (was 16GB)
— RAM offload makes bigger models viable on the 16GB-VRAM 6900XT.

Hardware: AMD RX 6900XT (gfx1030, RDNA2, 16GB VRAM) + 62GB RAM, ComfyUI on ROCm.
See [[box-hustle-llm]]. **NVFP4 quants are NVIDIA-Blackwell only — skip on AMD;
use FP8/GGUF.**

> **License gate (critical):** monetized YouTube = commercial use. Only
> commercial-OK models may be used for revenue work. Non-commercial models are
> personal/exploration only. License column below is load-bearing.

---

## Current stack (installed via install-comfyui.sh)

| Kind | Models present |
|---|---|
| Image | Flux 2, Flux Krea, Qwen-Image, SDXL |
| Video | Wan 2.2 14B (GGUF, T2V+I2V), Wan 2.2 TI2V-5B, LTX 2.3 |
| Audio | MusicGen, ACE-Step 1.5, HunyuanFoley, GPT-SoVITS, IndexTTS-2 |

Profiles: `image` (Flux/SDXL), `video-fast` (LTX), `video-quality` (Wan 2.2),
`music`, `music-light`.

---

## 1. Ideogram 4 — RESEARCHED ✓ (add, NON-COMMERCIAL)

First open-weight Ideogram model (released 2026-06-03). SOTA text rendering,
prompt adherence, bounding-box layout control. Flow-matching + **asymmetric CFG**
(two diffusion models: main + unconditional), Qwen3-VL text encoder, Flux-2 VAE.

**License: `ideogram-non-commercial`** → personal/exploration ONLY. Tag in
profile + docs so it never touches monetized work.

**Fit:** tested 16GB VRAM + 32GB RAM → 48-step image <5 min; our 62GB RAM gives
headroom (min ~6GB VRAM via offload). FP8 only on AMD.

**Files** (`Comfy-Org/Ideogram-4`, ungated as of 2026-06-09; HF token covers it):

| File | Dir | Size |
|---|---|---|
| `diffusion_models/ideogram4_fp8_scaled.safetensors` | diffusion_models | 8.64GB |
| `diffusion_models/ideogram4_unconditional_fp8_scaled.safetensors` | diffusion_models | 8.64GB |
| `text_encoders/qwen3vl_8b_fp8_scaled.safetensors` | text_encoders | 9.86GB |
| `vae/flux2-vae.safetensors` | vae | 0.31GB |
| | **total** | **~27.5GB** |

**Integration plan (deferred — batch with picks below):**
- Add 4 `grab(IDEO, "<path>", "<dir>", gated=True)` lines to install-comfyui.sh
  download block (`IDEO="Comfy-Org/Ideogram-4"`).
- Add `kijai/ComfyUI-KJNodes` to `clone_or_pull` (bounding-box prompt builder;
  basic t2i uses native `Ideogram4Scheduler`/`DualModelGuider`).
- ComfyUI must be recent for native nodes — `git pull` + restart covers it.
- Workflow: Comfy-Org template `image_ideogram4_t2i.json`.
- `image` profile already starts comfyui — no profile change (maybe add an
  `image-ideogram` note/variant tagged non-commercial).

---

## 2. Image candidates to evaluate next

| Model | Params | License | Notes vs our stack |
|---|---|---|---|
| **Ideogram 4** | — | non-commercial | researched above; text rendering king |
| Qwen-Image-2512 | 20B MMDiT | **Apache 2.0** | ✅ **ALREADY INSTALLED** (Q4_K_M). "Max" = closed API, no open weights. Only move = quant bump. See verdict. |
| ~~HunyuanImage 3.0~~ | 80B MoE / ~13B active | Tencent Community (commercial-OK) | ❌ **NOT VIABLE** — 24GB VRAM hard floor (we have 16GB), autoregressive (offload-hostile), CUDA/NF4-centric no ROCm. See verdict below. |
| FLUX.2 | DiT | BFL (commercial tiers) | we have Flux 2 — confirm latest 4MP build |
| HiDream-I1-Full | — | MIT-ish | strong all-rounder, commercial-OK |
| Chroma / SANA-Sprint | small | permissive | fast/low-VRAM options |
| SD 3.5 Large | 8B | Stability community | legacy baseline |

### HunyuanImage 3.0 — DEEP-DIVE VERDICT: rejected (2026-06-09)

Looked promising (80B MoE, commercial-OK license) but **does not fit 16GB VRAM**:
- Hard minimum **24GB VRAM** even at NF4 — no documented config runs below it.
  NF4 on a 24GB card already spills ~22GB to RAM; 16GB is under the floor.
- **Autoregressive**, not diffusion → CPU/RAM offload is slow and can't drop the
  resident VRAM below the floor the way Flux/SDXL diffusion can. 62GB RAM does
  not rescue it.
- NF4/INT8 paths are CUDA + bitsandbytes; **no ROCm support mentioned** — likely
  won't run on the 6900XT regardless.
Conclusion: the RAM upgrade unlocks big *LLM* MoEs (offload-friendly) but NOT
this autoregressive image MoE. Revisit only with a ≥24GB ROCm card.

Revised priority for the **commercial image-upgrade slot**: **Qwen-Image-2512**.

### Qwen-Image-2512 — DEEP-DIVE VERDICT: already installed; quant bump only (2026-06-09)

- **"Qwen-Image-Max" is Alibaba's closed API tier — no open weights.** The
  self-hostable model is `Qwen/Qwen-Image-2512` (20B MMDiT, **Apache 2.0**,
  released 2025-12-31). Fully commercial-safe — the go-to for monetized work.
- **We already run it.** install-comfyui.sh lines 311-314 pull
  `unsloth/Qwen-Image-2512-GGUF` Q4_K_M (12.33GB) + qwen2.5-vl-7b encoder + VAE,
  via the city96 ComfyUI-GGUF node we already have.
- Diffusion (MMDiT) → offload-friendly; unlike HunyuanImage it scales down
  cleanly. No VRAM-floor problem.
- **Only actionable upgrade: bump the quant** now that 62GB RAM gives headroom:
  | Quant | Size | 16GB VRAM |
  |---|---|---|
  | Q4_K_M (current) | 12.33GB | comfortable |
  | **Q5_K_M (recommend)** | 13.96GB | resident, ~2GB headroom |
  | Q6_K | 15.66GB | tight resident; OK via offload |
  One-line change: install-comfyui.sh:312 `qwen-image-2512-Q4_K_M.gguf` →
  `qwen-image-2512-Q5_K_M.gguf` (+ workflow `unet_name`). Defer to the batch.

## 3. Video candidates to evaluate next

| Model | Params | License | Notes |
|---|---|---|---|
| Wan 2.2 14B | 14B MoE | Apache | HAVE — still the open benchmark |
| LTX 2.3 | light | open | HAVE — fast iteration |
| **HunyuanVideo** | 13B | Tencent (check commercial) | cinematic, 720p 15s + audio; rivals Runway Gen-4 |
| Mochi 1 | 10B | Apache 2.0 | high-fidelity short clips, commercial-OK |
| SkyReels V1 | — | check | human-centric |

Priority: **HunyuanVideo** (audio + cinematic) and **Mochi 1** (Apache =
commercial-safe) as complements to Wan 2.2.

---

## Action items (deferred — implement as a batch after picks confirmed)

- [ ] Confirm licenses (commercial vs non-commercial) for HunyuanImage 3.0,
      Qwen-Image Max, HunyuanVideo, Mochi 1 — license is the gate.
- [ ] Verify HF repos + FP8/GGUF filenames + AMD/ROCm ComfyUI support for picks.
- [ ] Batch-edit install-comfyui.sh: Ideogram 4 (+KJNodes) + confirmed picks.
- [ ] Deploy downloads to box AFTER the LLM model pull finishes (shared ~10MB/s
      link — see [[box-hustle-llm]]).
- [ ] Tag non-commercial models in profiles/docs so they're excluded from
      monetized YouTube work.

---

## Citations

- [Ideogram 4 ComfyUI tutorial (docs.comfy.org)](https://docs.comfy.org/tutorials/image/ideogram/ideogram-v4)
- [Comfy-Org/Ideogram-4 (HF)](https://huggingface.co/Comfy-Org/Ideogram-4)
- [Next Diffusion — Ideogram 4 in ComfyUI](https://www.nextdiffusion.ai/tutorials/ideogram-4-controlled-text-to-image-generation-in-comfyui)
- [AI Search — "New BEST local AI image generator" (yt OA4gchz1Zcs)](https://www.youtube.com/watch?v=OA4gchz1Zcs)
- [BentoML — open-source image models 2026](https://www.bentoml.com/blog/a-guide-to-open-source-image-generation-models)
- [Hyperstack — open-source video models 2026](https://www.hyperstack.cloud/blog/case-study/best-open-source-video-generation-models)
