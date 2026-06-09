# Research findings — June 2026 (64GB RAM tier)

Trigger: system RAM upgraded 16GB → 62GB usable. This unlocks a whole new
class of models (100B+ MoE via CPU expert offload) that the May doc's 16GB
tier could not touch. This pass re-picks the `64gb` tier of
`install-llama-server-rocm.sh`.

Hardware target: AMD RX 6900XT (gfx1030, RDNA2, **16GB VRAM**) + **62GB RAM**,
Linux ROCm, llama.cpp with `--n-cpu-moe` expert offload. AMD/ROCm runs a bit
slower than the NVIDIA reference numbers below, but offload mechanics are
identical.

Sources: live web search (glukhov.org llama.cpp 16GB benchmarks, llama.cpp
gpt-oss discussion, carteakey gpt-oss-120b tuning), plus YouTube head-to-head
channels @tokenchaser + @Bijanbowen (view counts via vidIQ MCP = community
signal). Citations at bottom.

---

## TL;DR — what the RAM upgrade changes

1. **100B+ MoE is now on the menu.** With 62GB RAM the cold experts live in
   system memory; only the hot ~3-10B active path + attention sit on the 16GB
   GPU. `Qwen3.5-122B-A10B` (IQ3_XXS) runs at **21.5 t/s @ 64K ctx, 14.7GB
   VRAM**, and `gpt-oss-120b` at **~25 t/s** (RAM-bandwidth bound).

2. **Quant choice flips.** The current 64gb tier pulls `Q4_K_M`. That's fine
   for ≤35B, but the 100B-class models only fit 16GB VRAM at the small
   imatrix quants — `UD-IQ3_XXS` / `IQ4_XS`. Q4_K_M of a 122B will not fit.

3. **RAM bandwidth is the throttle, not the GPU.** For the big-offload models,
   token rate ≈ memory speed. **Enable EXPO/XMP in BIOS** — running RAM at
   JEDEC vs rated can ~3× generation speed on 120B-class models.

4. **Community breakout: Gemma 4 12B.** Highest-viewed local-coding video in
   the tracked channels (64k views, "best local coding model yet?"). At Q8 it
   runs *fully* in 16GB VRAM — fast, no offload, strong coding. Best "always
   loaded, instant" pick.

5. **Skip speculative decoding for A3B MoE** — still net-negative on consumer
   hardware (carried from May doc, re-confirmed).

---

## Concrete picks for the 64GB tier (16GB VRAM + 62GB RAM)

| Role | Model | Quant | Speed (ref) | VRAM | Notes |
|---|---|---|---|---|---|
| **Fast general (default)** | Qwen3.5-35B-A3B | UD-IQ3_XXS | ~147 t/s @19K | 13.8GB | near-fully on GPU, blistering |
| **Daily coding** | Qwen3-Coder-Next (38B MoE) | UD-IQ4_XS | ~41 t/s @19K | 14.6GB | upgrade over Qwen3-Coder-30B |
| **16GB instant coder** | Gemma 4 12B | Q8 | fast, no offload | ~13GB | community fave, fits fully |
| **Efficient coder alt** | GLM-4.7-Flash-REAP-23B | IQ4_XS | ~123 t/s @32K | 14.4GB | pruned GLM, very efficient |
| **Max quality / long ctx** | Qwen3.5-122B-A10B | UD-IQ3_XXS | ~21.5 t/s @64K | 14.7GB | **needs the 62GB RAM** |
| **Max quality alt** | gpt-oss-120b | MXFP4 | ~25 t/s | offload-heavy | RAM-bandwidth bound; EXPO! |
| **Long-context specialist** | MiniMax M3 | (TBD) | — | — | hybrid attn, low KV balloon; open weights pending |

Reference speeds are NVIDIA (3090 / glukhov suite). Expect AMD 6900XT to land
meaningfully lower but in the same ballpark; tune `--n-cpu-moe` down until OOM,
then back off one.

### Recommended default mapping
- `moe-fast`    → **Qwen3.5-35B-A3B UD-IQ3_XXS** (fast daily driver)
- `moe-coder`   → **Qwen3-Coder-Next UD-IQ4_XS** (agentic coding)
- `moe-quality` → **Qwen3.5-122B-A10B UD-IQ3_XXS** (was GLM-4-32B; now true heavy tier)
- (new) `moe-instant` → **Gemma 4 12B Q8** (always-loaded, fits VRAM, zero offload latency)

---

## Community signal — tracked channels (June 2026)

View-ranked head-to-heads (vidIQ MCP). Views = what the local-LLM community is
actually weighing right now.

| Views | Video | Takeaway for us |
|---|---|---|
| 64.3k | Gemma 4 12B — "best local coding model yet?" (@Bijanbowen) | 16GB-friendly, runs fully in VRAM |
| 18.1k | Nemotron 3 Ultra first look (@Bijanbowen) | too big for 16GB; skip |
| 17.8k | Qwen3.7 Plus first test (@Bijanbowen) | newest mid-size Qwen; watch for GGUF |
| 12.7k | Step 3.7 Flash local test (@Bijanbowen) | creative; Q8 ~50 t/s on M3 Ultra (not our rig) |
| 7.6k | MiniMax M3 (@Bijanbowen) | long-ctx champ, low KV balloon; open weights pending |
| 6.3k | GPT-5.5 vs Qwen3.6 27B MTP (@tokenchaser) | Qwen3.6 27B competitive locally vs cloud |
| 6.2k | Qwen3.6 27B Q8 vs Claude Sonnet 4.6 (@tokenchaser) | Sonnet still edges it; Qwen close |
| 4.8k | Qwen3.6 27B vs Heretic NEO Code 27B (@tokenchaser) | coding-tuned 27B alternatives |
| 3.5k | Gemma4 31B vs Qwen3.6 27B (@tokenchaser) | Gemma4 31B ~31 t/s on 3090 |

Transcripts: `docs/transcripts/{tokenchaser,Bijanbowen}/`.

---

## Action items

- [x] Update `install-llama-server-rocm.sh` 64gb tier: quants switched to
      `UD-IQ3_XXS` / `IQ4_XS`, models repointed per mapping above.
- [x] Add `moe-instant` (Gemma 4 12B Q8). Extended profile override to carry
      per-model `NCPUMOE` + `CTX`. (GLM-4.7-Flash dropped — not wanted.)
- [x] Verify HF repos exist before wiring — confirmed on HF 2026-06-09
      (all 5 unsloth repos, single-file GGUFs). Fragile fallback chain removed
      (was the silent `DEFAULT_MODEL` name-mismatch source).
- [ ] Confirm EXPO/XMP enabled in BIOS (gates 120B-class speed).
- [ ] `n-cpu-moe` values are conservative starting points — tune down per
      model until OOM, back off one (122B=40, coder=10, glm=6, fast=8).
- [ ] Re-run `./scrape-channels.sh` weekly; watch Qwen3.7 GGUF + MiniMax M3
      open-weight drop.

---

## Citations

- [glukhov.org — 16GB VRAM llama.cpp benchmarks](https://www.glukhov.org/llm-performance/benchmarks/best-llm-on-16gb-vram-gpu/)
- [glukhov.org — OpenCode LLMs compared (Gemma 4 → Qwen 3.6)](https://www.glukhov.org/ai-devtools/opencode/llms-comparison/)
- [llama.cpp — running gpt-oss guide (discussion #15396)](https://github.com/ggml-org/llama.cpp/discussions/15396)
- [carteakey.dev — optimizing gpt-oss-120b on consumer hardware](https://carteakey.dev/blog/local-inference/optimizing-gpt-oss-120b-local-inference/)
- [Qwen3-Coder-Next 2026 guide (DEV)](https://dev.to/sienna/qwen3-coder-next-the-complete-2026-guide-to-running-powerful-ai-coding-agents-locally-1k95)
- [Pinggy — best self-hosted coding LLMs 2026](https://pinggy.io/blog/best_open_source_self_hosted_llms_for_coding/)
- YouTube head-to-heads: [@tokenchaser](https://www.youtube.com/@tokenchaser/videos), [@Bijanbowen](https://www.youtube.com/@Bijanbowen/videos) (view counts via vidIQ MCP, 2026-06-09)
