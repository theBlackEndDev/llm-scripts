# Tensor Alchemist Channel Notes

Findings from @TensorAlchemist 8GB VRAM workflow series (Mar-Apr 2026). His benchmarks on RTX 5060 8GB + 32GB RAM directly informs our 6900XT 16GB + 16/64GB RAM tiering.

## Per-model settings we use

### Wan 2.2 14B GGUF (T2V/I2V)

- Q4_K_M = 9GB (our 16GB RAM tier)
- Q6_K = 12GB (32GB RAM tier comfortable)
- Two model files (high noise + low noise), 22GB combined Q6
- 640p resolution recommended below 8GB; 720p OOM on 8GB but fine on 16GB
- Has integrated upscaler in workflow → 1080p output from 640p source
- Lightning 4-step LoRA already baked into newer checkpoints

### Wan 2.2 5B Turbo Q8 GGUF (NEW - add to stack)

- Native 1440p possible on 8GB VRAM
- **4 steps only**, CFG=1, no negative prompt issues
- `model_sampling.shift = 5` (default 8) — aligns with turbo noise schedule
- Sampler: **SS solver** (or UniPC fallback)
- Scheduler: **beta** (or simple/normal)
- NAG node `energy_scale = 35` — boosts negative prompt at low CFG
- 1440p 12fps 5s clip ≈ 13.5min on 8GB
- 1080p ≈ 6.5min, 720p ≈ 3min, 480p ≈ 1.5min
- Post 8K image gen, animate with this for 1440p video

### LTX 2.3 v1.1

- FP8 (23GB) works on 8GB VRAM via SSD swap (stresses SSD)
- Q5_K_M GGUF (16GB) safer
- 8 steps, CFG=1 (distilled), sampler **euler_ancestral**
- Tile VAE decode: tile_size=128, overlap=32 for 30s clips
- Audio VAE goes in `checkpoints/` folder (not `vae/`)
- 1080p 24fps 10s ≈ feasible; 540p 24fps 30s common
- Stick to 5-6 core actions in prompt, single flowing paragraph
- Avoid words like "violently"; use "smooth", "controlled" instead
- v1.1 vs base 2.3: huge spatial/lighting/style improvements
- Still weak: hand-object interaction, big zooms on faces, multi-stage physics

### LTX 2.3 Lip-Sync LoRA (NEW)

- First community AV LoRA for LTX 2.3
- Talking-head with synchronized lip sync from reference voice
- Trigger word required (check LoRA model card)
- **End your prompt with the speech transcript** for better lip sync
- 25-26s 540p 24fps clip ≈ 18-24min on 8GB w/ Sage Attention (slower on AMD without)
- FP8 input-scaled v3 (Kijai, 25GB) or Q5_K_M GGUF
- Connect: U-Net loader → Load LoRA → CFG Guider (anything-everywhere)

### ACE-Step 1.5 (music with vocals)

- 8 steps, CFG=1 (turbo), sampler **LCM**, scheduler **beta 57**
- 130 BPM common starting point
- Two text fields: style/genre + lyrics
- 60-80s for full song on 8GB VRAM

### LTX-2 (older base, not v2.3)

- Use **distilled** models, NOT dev models
- Text encoder: **Gemma 3 GGUF** version
- 540p 24fps 30s ≈ 12min on 8GB
- 4-8 sentence prompt, single paragraph, present tense

## Workflow tricks

### NAG (Negative Attention Guidance) node

Boosts negative prompt influence at low CFG (typical for turbo/distilled models):
```
WanVideoNAG.energy_scale = 35
```

### Tile VAE Decode

For long clips on tight VRAM:
```
tile_size = 128
overlap = 32
```

### Order: interpolate → upscale (NEVER reverse)

- Interpolate 25→50fps on 1080p 10s clip ≈ 4-5min
- Upscale 1080p 25fps → 4K ≈ 2-3min (32GB system RAM)
- Upscale 1080p 50fps → 4K ≈ 15-18min (SSD swap thrash, kills SSD lifetime)
- Sweet spot for 32GB RAM: stop at 1440p
- For 16GB RAM: stop at 1080p

### ComfyUI native frame interpolation workflow

Templates → Video frame interpolation. Better than ffmpeg minterpolate.

## Audio

### Hunyuan-Foley (NEW - add to stack)

Adds audio to existing Wan 2.2 video clips post-generation. Avoids OOM that simultaneous video+audio gen causes on tight VRAM.

- Separate workflow, runs after video gen
- 2-3 minutes per clip (1st time slower, ~3min; cached after, ~2min)
- Strong at ambient sound; tweak prompt for specifics
- Frame rate + duration must match source video
- Negative prompt useful for filtering "loud background melodies, distortion"

## Image gen alternatives we considered

### Z-Image Turbo + Instagramification LoRA

For "Insta model" style faces (anti-plastic-skin). 16 steps, CFG=1, detail amount 0.16, sampler euler, scheduler SDGM uniform. Trigger `IG Barry` per LoRA. **Skip — overlaps with Flux Krea, niche use case.**

### ERNIE Image Turbo (Baidu, single-stream DiT)

8 steps only (vs 30-50 standard). Excellent at readable text, multi-panel layouts, structured posters. FP8 / GGUF for low VRAM. **Skip for now — Flux Krea covers most needs; ERNIE shines for poster/comic work specifically.**

## LLM upgrade path

### Gemma 4 26B (release recent)

- Q4_K_M ≈ 18GB, Q4_K_S ≈ 16.6GB
- 256K context window
- Vision capable
- Run via **LM Studio** with explicit GPU/RAM split:
  - GPU offload layers: ~10 (~5.9GB VRAM)
  - CPU thread pool: 8
  - Eval batch: 512 (don't go higher, OOM risk)
  - KV cache offload to GPU: **OFF** (keep in system RAM)
  - MoE layers forced to CPU: 30 (max safety valve)
  - Flash attention: ON
  - mmap: ON
  - Quantization: Q4
- Unfiltered community fine-tunes available
- **Upgrade target after 32GB RAM** (system RAM hosts most layers)

## Cloud supplement

### Seedance 2.0 (closed, paid)

LTX 2.3 wins on: open Apache 2.0, local, unlimited, unfiltered, free upscalers.

Seedance wins on: cinematic camera control, motion consistency on fast action, prompt adherence, ease of use.

**Strategy:** use Seedance ONLY for the 1-2 hero action shots LTX 2.3 can't handle (high-octane chase scenes, complex camera moves with multiple moving subjects). Everything else local.

## Versions (his stable env, Apr 2026)

- Python 3.12 in ComfyUI venv (we use 3.11; should still work)
- CUDA 13.1 (N/A for us, ROCm path)
- ComfyUI nightly for testing; stable for production
- PyTorch ROCm 6.2 for our path

## Channel value

Tensor Alchemist publishes ~2-3x/week, focused on 8GB VRAM workflows. Most relevant subset for our use:
- LTX 2.3 series (5+ videos)
- Wan 2.2 variants
- ACE-Step / music
- Z-Image Turbo
- Flux 2 Klein 9B
- Lip-sync workflows

Subscribe + watch new uploads weekly. He has `frame interpolation` and `RTX super resolution` workflows we should adapt for AMD path (substitute SeedVR2 or Real-ESRGAN).
