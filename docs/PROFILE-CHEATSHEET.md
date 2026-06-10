# Profile → use-case cheatsheet

Switch with `sudo profile <name>` on the box (hustle-llm). One profile = one
GPU job; switching stops the others (16GB VRAM can't run everything at once).
LLM tps numbers are measured on the 6900XT + 62GB RAM (2026-06-09).
`✅` = commercial-safe license, `⚠️` = personal/non-commercial only.

---

## "I want to…" → profile

| I want to… | profile | runs |
|---|---|---|
| Quick chat / snappy Q&A | `moe-instant` | Gemma-4-12B (instant) |
| **Daily LLM driver** | `moe-fast` | Qwen3.5-35B-A3B (fastest) |
| Agentic coding / hard code | `moe-coder` | Qwen3-Coder-Next 80B |
| Max reasoning (wait for it) | `moe-quality` | Qwen3.5-122B |
| Vision / 256K-context chat | `gemma4-26b` | Gemma-4-26B (ollama) |
| Dictate text + cleanup | `dictate` | whisper + qwen3.5:9b |
| Full voice assistant loop | `assistant` | whisper + LLM + GPT-SoVITS |
| **Generate an image** | `image` | Z-Image/HiDream/Qwen/Chroma/Flux/SDXL |
| Edit / restore an image | `image-edit` | Qwen-Image-Edit-2511 / OmniGen2 |
| Fast video + audio | `video-fast` | LTX 2.3 |
| Quality hero video | `video-quality` | Wan 2.2 14B |
| Character swap / lip-sync | `video-animate` | Wan 2.2 Animate |
| Make music / beats | `music` | ACE-Step / MusicGen |
| Train a voice | `train-tts` | GPT-SoVITS |
| Free all VRAM (idle) | `off` | — |

---

## LLM profiles (llama-server :8081, verified speeds)

| profile | model | gen tps | prompt tps | load | RAM | best for |
|---|---|---|---|---|---|---|
| `moe-instant` | Gemma-4-12B Q8 (dense) | 28.8 | **188.7** | 10s | 3GB | snappy short replies, fast prefill |
| `moe-fast` | Qwen3.5-35B-A3B IQ3_XXS | **44.0** | 61.6 | 16s | 5GB | **daily driver** — fastest gen |
| `moe-coder` | Qwen3-Coder-Next 80B IQ4_XS | 16.5 | 22.6 | 30s | 31GB | agentic coding, hard tasks |
| `moe-quality` | Qwen3.5-122B IQ3_XXS | 12.3 | 17.0 | 47s | 34GB | deepest reasoning |

Switching between these reloads the model (~15-47s). All served at
`http://hustle-llm:8081/v1` + visible in Open WebUI (:3000).

### Older ollama-based LLM profiles
| profile | model | best for |
|---|---|---|
| `gemma4-light` | gemma4:e4b | tiny/fast, fits anywhere |
| `dev` | whisper + qwen3.5:9b | coding with dictation |
| `chat-big` | gpt-oss:20b | heavy reasoning (ollama path) |
| `gemma4-26b` | gemma4:26b | vision + 256K context |

---

## Image — profile `image`, pick model by job

ComfyUI loads; choose the model in the workflow. Match model to the job:

| Job | Model | License |
|---|---|---|
| Fast drafts / bulk / thumbnails | **Z-Image Turbo** (~2-3s) | ✅ Apache |
| Final / hero quality | **HiDream-I1** or Qwen-Image-2512 | ✅ MIT / Apache |
| Text in image (signage, UI, infographics) | **Qwen-Image-2512** | ✅ Apache |
| Uncensored / stylized / experimental | **Chroma1-HD** | ✅ Apache |
| Typography / posters / comics | **Ideogram 4** | ⚠️ personal only |
| Anime / illustration | SDXL (Illustrious/NoobAI/Pony) | mostly ✅ |
| Photoreal personal hero | Flux 2 / Krea | ⚠️ non-commercial |

**Edit existing image** → profile `image-edit`: Qwen-Image-Edit-2511 (restore/
instruction edit) or OmniGen2 (unified). ✅ Apache.

---

## Video — pick profile by job

| Job | profile | Model | License |
|---|---|---|---|
| Fast clip WITH synced audio | `video-fast` | LTX 2.3 | conditional ✅ |
| Quality hero shot / B-roll | `video-quality` | Wan 2.2 14B (I2V) | ✅ Apache |
| Character swap / talking-head / lip-sync | `video-animate` | Wan 2.2 Animate | ✅ Apache |
| Short commercial clip (faster than Wan 14B) | `video-quality`* | Mochi 1 | ✅ Apache |

\* Mochi shares the `image`/ComfyUI stack — load it in a ComfyUI workflow.

---

## Voice & music

| profile | runs | best for |
|---|---|---|
| `assistant` | whisper + LLM + GPT-SoVITS | full voice assistant loop |
| `dictate` | whisper + qwen3.5:9b | dictation + punctuation cleanup |
| `train-tts` | GPT-SoVITS | fine-tune a voice |
| `tts-bench` | GPT-SoVITS + LLM | TTS inference + prompt LLM |
| `music` | ACE-Step / MusicGen | beats / songs (low VRAM) |
| `music-light` | ComfyUI + LLM + whisper | full creative music loop |

---

## Example pipelines (chain profiles)

1. **Commercial YouTube B-roll:** `image` (Qwen/HiDream still) → `video-quality`
   (Wan 2.2 I2V) → interpolate/upscale. All ✅.
2. **Fast social short:** `image` (Z-Image Turbo) → `video-fast` (LTX, +audio). ✅
3. **AI avatar / talking head:** `image` (HiDream character) → `video-animate`
   (Wan Animate, lip-synced to a `train-tts`/GPT-SoVITS voice). ✅
4. **Coding session:** `moe-coder` for agentic work, drop to `moe-fast` for speed.
5. **Photo restore:** `image-edit` (Qwen-Image-Edit-2511). ✅

Sources: [[box-hustle-llm]], docs/RESEARCH-2026-06.md (LLM),
docs/RESEARCH-2026-06-image-video.md (image/video roles + licenses).
