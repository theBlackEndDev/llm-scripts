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

## 2. Image models — full landscape (June 2026)

Licenses + 16GB-VRAM fit verified on HF 2026-06-09. **Commercial = usable for
monetized YouTube.** GGUF runs via our existing city96 ComfyUI-GGUF node.

### A. General base — COMMERCIAL-safe, fits 16GB ⭐ (the additions that matter)

| Model | License | Arch | 16GB fit | Why |
|---|---|---|---|---|
| **Z-Image Turbo** | Apache 2.0 | distilled DiT | fp8 / GGUF, ~2-3s/img (8 steps) | **speed champion**, "beats Flux.2", sub-3s. Best fast daily driver. Alibaba Tongyi, Nov 2025. |
| **HiDream-I1-Full** | **MIT** | 17B sparse DiT | GGUF Q4_K_M 10.7GB / Q5_K_M 12.1GB | top-tier quality all-rounder, fully commercial |
| Qwen-Image-2512 | Apache 2.0 | 20B MMDiT | GGUF Q4_K_M 12.3GB | ✅ HAVE; bump Q4→Q5 (see verdict) |
| **Chroma1-HD** | Apache 2.0 | 8.9B (Flux-schnell base) | GGUF Q4_0 **5GB** | uncensored, tiny, flexible, de-distilled |
| SANA / SANA-Sprint | NVIDIA (check) | 0.6B linear-DiT | tiny | 20× smaller than Flux-12B, 100× throughput |

### B. Editing / instruction — COMMERCIAL (we currently have NO editor)

| Model | License | 16GB fit | Why |
|---|---|---|---|
| **Qwen-Image-Edit-2511** | Apache 2.0 | ~Qwen-Image size | pairs with our Qwen-Image; great restoration/instruction edit |
| **OmniGen2** | Apache 2.0 | 7B (3B+4B), ComfyUI native | unified gen+edit, uses Qwen-VL-2.5 |
| Flux Kontext | BFL non-comm | fp8 | edit; non-commercial |

### C. General base — NON-COMMERCIAL / closed (personal only or not self-hostable)

| Model | Status | Note |
|---|---|---|
| Ideogram 4 | non-commercial | text-render king; planned (personal), see §1 |
| FLUX.2 [dev] | BFL non-comm | 32B — struggles on 16GB without heavy quant + slow offload; we have Flux 2 |
| **Nano-Banana / NB2 / Pro** | **CLOSED — Google API only** | NOT open weights. "Open-source Nano-Banana" videos are clickbait — it's a ComfyUI *partner API node*, not self-hostable. Skip. |
| ~~HunyuanImage 3.0~~ | rejected | 24GB VRAM floor — see verdict below |

### D. Anime / illustration — SDXL ecosystem (all run easily on 16GB)

Illustrious XL, **NoobAI XL** (v-pred, highest quality, CFG ~3.5), Pony Diffusion
v6/v7, **Animagine XL 4.0** (cleanest line art, 8.4M-image train). Civitai
community checkpoints, mostly permissive/Fair-AI licenses (verify per-model for
commercial). We already support the SDXL pipeline — these are drop-in checkpoints.

### Recommended commercial additions (priority order)
1. **Z-Image Turbo** — fast Apache daily driver (huge speed win on our rig)
2. **HiDream-I1-Full** (MIT) — commercial quality all-rounder
3. **Qwen-Image-Edit-2511** or **OmniGen2** — adds editing (capability gap today)
4. **Chroma1-HD** — uncensored/flexible, 5GB
Personal-only: **Ideogram 4** (text rendering).

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

## 3. Video models — full landscape (June 2026)

Licenses verified on HF 2026-06-09. 14B-class needs GGUF Q5_K_M for 16GB; clips
are slow on our card (~10-15 min at 480-720p) — Wan is quality-not-speed.

| Model | License | Status | Good at | Weak at |
|---|---|---|---|---|
| **Wan 2.2 14B** (T2V+I2V) | Apache 2.0 | HAVE | best open quality + motion, commercial | slow on 16GB, no native audio |
| **Wan 2.2 TI2V-5B** | Apache 2.0 | HAVE | lighter/faster Wan, native 1440p, single model | less detail than 14B |
| **Wan 2.2 Animate-14B** | Apache 2.0 | ⭐ ADD | **character swap + lip-sync**, motion transfer, commercial | not from-scratch gen; needs driving video |
| **LTX 2.3** | Lightricks (conditional commercial) | HAVE | **near-real-time + native synced AUDIO + 4K + low VRAM** | motion fidelity below Wan |
| HunyuanVideo 1.5 | Tencent "other" (territorial) | candidate | physics/motion realism (fluid, cloth, dynamics), cinematic | non-Apache, no native audio/I2V in base, 16-24GB |
| Mochi 1 | Apache 2.0 | candidate | high-fidelity short T2V, commercial-safe | no audio, no I2V, short clips only |
| SkyReels V2 | "other" (Hunyuan base) | candidate | cinematic humans, facial animation, camera moves | non-Apache license |
| CogVideoX-5b | custom (free-ish) | candidate | light/fast, 6s clips | low res/quality |
| ~~Wan 2.5~~ | — | skip | — | appears **API-only**, no open weights |

**Recommended commercial video adds:** **Wan 2.2 Animate** (unlocks character
swap / lip-sync / avatars — biggest new *capability*) and **Mochi 1** (Apache,
faster short-clip alternative to the slow Wan 14B). HunyuanVideo 1.5 / SkyReels
= personal-only until license cleared.

---

## 4. Roles & use-cases — what each model is FOR

Your stack is a toolkit, not one model. Match the model to the job.

### Image — pick by job

| Job | Use | Avoid | License |
|---|---|---|---|
| **Fast drafts / bulk / thumbnails at scale** | **Z-Image Turbo** (~2-3s) | — | Apache ✅ |
| **Final/hero commercial images** | **HiDream-I1** (MIT) or Qwen-Image-2512 | Z-Image (less detail) | MIT / Apache ✅ |
| **Text-in-image, signage, UI mockups, infographics** | **Qwen-Image-2512** | Chroma (weak text) | Apache ✅ |
| **Typography / posters / comics / layout control** | **Ideogram 4** (bounding boxes) | — | non-commercial ⚠️ personal only |
| **Uncensored / stylized / experimental art** | **Chroma1-HD** | Qwen (more literal) | Apache ✅ |
| **Anime / illustration / character art** | **SDXL: Illustrious / NoobAI / Pony / Animagine** + LoRAs | photoreal models | mostly permissive (verify) |
| **Edit / restore / inpaint existing image** | **Qwen-Image-Edit-2511** or **OmniGen2** | from-scratch gen models | Apache ✅ |
| **Photoreal personal hero** | Flux 2 (HAVE) | — | BFL non-comm ⚠️ |

### Video — pick by job

| Job | Use | Avoid | License |
|---|---|---|---|
| **Quality hero shot / B-roll** | **Wan 2.2 14B** (I2V from a still) | LTX (less fidelity) | Apache ✅ |
| **Fast social clip WITH audio** | **LTX 2.3** (T2V + synced audio, 4K) | Wan (slow, silent) | conditional ✅ |
| **Talking head / avatar / lip-sync** | **Wan 2.2 Animate** + GPT-SoVITS voice | T2V models | Apache ✅ |
| **Character swap in existing footage** | **Wan 2.2 Animate** | — | Apache ✅ |
| **Commercial short clip, faster than Wan 14B** | **Mochi 1** | HunyuanVideo (license) | Apache ✅ |
| **Physics-heavy / cinematic motion** | HunyuanVideo 1.5 / SkyReels | — | "other" ⚠️ personal |
| **Quick light test clip** | Wan TI2V-5B or CogVideoX | 14B (slow) | Apache ✅ |

### Example pipelines (chain the toolkit)

1. **Commercial YouTube B-roll:** Qwen-Image-2512 / HiDream (still) → Wan 2.2 I2V
   (motion) → Frame-Interpolation (smooth) → upscale. All Apache/MIT. ✅
2. **Fast social short:** Z-Image Turbo (frames) → LTX 2.3 (video + native audio)
   → done in minutes. ✅
3. **AI avatar / talking head:** HiDream (character still) → Wan 2.2 Animate
   (lip-sync to your GPT-SoVITS voice track). ✅
4. **Anime short:** Illustrious/NoobAI (+character LoRA) → Wan 2.2 I2V.
5. **Photo restore / product edit:** Qwen-Image-Edit-2511 or OmniGen2. ✅
6. **Personal poster/comic with text:** Ideogram 4 (typography + panels). ⚠️ personal
7. **Bulk thumbnail A/B testing:** Z-Image Turbo (speed) or Qwen (text overlays). ✅

> Profiles map to these: `image` (Z-Image/HiDream/Qwen/SDXL), `video-fast`
> (LTX 2.3), `video-quality` (Wan 2.2). Consider adding `image-edit`
> (editor models) and `video-animate` (Wan Animate) profiles.

---

## Action items (deferred — implement as a batch after picks confirmed)

- [x] Licenses confirmed (HF 2026-06-09): commercial-safe = Z-Image Turbo,
      HiDream-I1 (MIT), Chroma, Qwen-Image-Edit-2511, OmniGen2, Wan 2.2/Animate,
      Mochi 1. Personal-only = Ideogram 4, Flux 2-dev, HunyuanVideo, SkyReels.
- [ ] Verify exact GGUF/FP8 filenames for the chosen adds before wiring
      (image done for HiDream/Chroma/Qwen; video Mochi/Wan-Animate pending).
- [x] Batch-edited install-comfyui.sh (2026-06-09): image (Z-Image Turbo,
      HiDream-I1 Q5, Qwen-Image-Edit-2511, Chroma1-HD, Ideogram 4 +KJNodes,
      Qwen-2512 Q4→Q5) + video (Wan 2.2 Animate Q5, Mochi 1 fp8). Filenames
      verified on HF; reuses existing encoders/VAEs.
- [ ] Add profiles: `image-edit` (editors), `video-animate` (Wan Animate).
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
- [Tongyi-MAI/Z-Image-Turbo (HF, Apache 2.0)](https://huggingface.co/Tongyi-MAI/Z-Image-Turbo) · [Z-Image Turbo ComfyUI guide](https://docs.comfy.org/tutorials/image/z-image/z-image-turbo)
- [HiDream-ai/HiDream-I1-Full (HF, MIT)](https://huggingface.co/HiDream-ai/HiDream-I1-Full) · [city96 HiDream GGUF](https://huggingface.co/city96/HiDream-I1-Full-gguf)
- [lodestones/Chroma (HF, Apache 2.0)](https://huggingface.co/lodestones/Chroma)
- [OmniGen2 ComfyUI native](https://docs.comfy.org/tutorials/image/omnigen/omnigen2) · [Qwen/Qwen-Image-Edit-2511 (HF, Apache 2.0)](https://huggingface.co/Qwen/Qwen-Image-Edit-2511)
- [Diffusion Doodles — Z-Image/Qwen-2512/Flux.2 rundown](https://medium.com/diffusion-doodles/model-rundown-z-image-turbo-qwen-image-2512-edit-2511-flux-2-dev-fc787f5e87ad)
