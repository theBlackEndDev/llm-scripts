# Research findings — May 2026

Sources: r/LocalLLaMA, HuggingFace trending, llama.cpp discussions, ROCm blog,
Codacus YouTube channel, Phoronix benchmarks. See bottom for citations.

## TL;DR — what we should add to the stack

1. **llama-server with MoE expert offload** (`--n-cpu-moe`, `-ngl 999`,
   `-fa on`, `--cache-type-k q8_0`) — runs 20-35B models on 16GB rigs.
   Implemented: `install-llama-server-rocm.sh`.

2. **Bump ROCm 6.4 → 7.1.1** when stable on Ubuntu 24.04 — claimed 5.4×
   ComfyUI perf uplift. Watch the ROCm channel.

3. **Sage Attention + Flash Attention + Triton on Linux ROCm**
   (via `patientx-cfz/comfyui-rocm` packages) — works on RDNA2 now.
   Big speedup on Wan/Flux/SDXL.

4. **Skip speculative decoding for MoE A3B**. Net-negative on consumer
   hardware per April 2026 benchmarks (RTX 3090 reference). MoE expert
   loading overhead outweighs draft savings.

5. **Skip ZLUDA**. Faster on Windows but Linux ROCm + Sage Attention
   closes the gap. We're Linux-first.

## Top open-weight LLMs (May 2026)

| Model | Total / Active | SWE-Bench | Best for | Fits |
|---|---|---|---|---|
| GLM-4.7 | 32B dense | **74.2** | coding agents | 64GB RAM Q4 |
| Qwen3-Coder-Next | 80B / 3B MoE | 70.6 | coding agents | 64GB RAM |
| DeepSeek-V3.2 | 671B / 37B MoE | 70.2 | top-tier coding | server-class only |
| Mistral Devstral | small + 256K ctx | 72.2 | long-context coding | 32GB RAM Q4 |
| Qwen3.5-35B-A3B | 35B / 3B MoE | competitive | general MoE | 32GB RAM Q4 |
| Qwen3.6-35B-A3B | 35B / 3.6B MoE | newer | general MoE | 32GB RAM Q4 |
| gpt-oss-20B (MXFP4) | 20B / 3.6B MoE | strong | sweet spot | **16GB RAM** |
| Llama 3.3 70B | 70B dense | 67ish | best general | 64GB+ RAM Q4 |
| Mistral Small 3 | small dense | mid | drop-in replacement | 16GB RAM |

**For your 16GB-RAM tier**: `gpt-oss-20b` MXFP4 = 12.5GB, runs near-fully on
6900XT. Reported ~28-32 tok/s on 16GB AMD cards via Vulkan.

**For your 64GB-RAM tier (post-upgrade)**: `Qwen3.5-35B-A3B Q4_K_M` daily,
`GLM-4.7 Q4_K_M` for coding agent work, `Mistral Devstral Q4` for long-context.

## TTS — beyond GPT-SoVITS

We have GPT-SoVITS v4 (training) + IndexTTS-2 (zero-shot). 2026 leaders:

| Model | Strength | Add? |
|---|---|---|
| **Fish Speech V1.5** | TTS-Arena2 #1, 80+ languages | Yes — multi-lang shows |
| **Voxtral** | Beats ElevenLabs Flash 2.5 in blind tests | Yes — natural prosody |
| **CosyVoice2-0.5B** | Tiny, fast, expressive | Optional |
| **Chatterbox** (Resemble AI) | Real-time, low GPU need | Optional |
| **F5-TTS** | Strong zero-shot | Optional |
| **Kokoro** | Tiny model, decent quality | Skip |
| **XTTS v2** | Older but stable | Already established |

Recommendation: add Fish Speech V1.5 install script alongside existing TTS
stack. Different strengths than GPT-SoVITS (multi-lang, no training).

## Music — keep what we have

ACE-Step 1.5 + MusicGen Stereo Large are still the best local options:

- **ACE-Step 1.5**: best all-around, AMD-tested, 4-min songs in 20s
- **MusicGen Stereo**: best for instrumental beats / B-roll
- **DiffRhythm / YuE**: full-song with vocals, niche
- **Stable Audio Open**: short-form / sound design only — useful for
  riffs and ambient textures, not finished tracks

No changes needed unless you want DiffRhythm/YuE for vocal songs.

## Image — Flux2 viable post-RAM upgrade

Already in plan. After 64GB RAM:
- Flux.2 Dev Q5_K_M (Mistral-Small encoder, ~22GB peak) viable
- Flux.1 Krea Q8 comfortable
- Qwen-Image-2512 Q4 comfortable
- 2048x2048 with Tile VAE

## Video — keep Wan, watch LTX 2.3

For ROCm path:
- **Wan 2.2 14B Q4_K_M** stays primary motion model (works on 16GB VRAM via
  GGUF dual-expert). Q5_K_M after RAM upgrade.
- **LTX 2.3 v1.1** unlocks at 64GB RAM. Faster than Wan, native audio, top-tier.
- **CogVideoX-5B** as smaller backup option (works on 16GB VRAM clean).
- **HunyuanVideo Foley** for ambient SFX (we have this).

For Intel Arc B70 (if user switches): Wan broken (fp64 bug), LTX 2.3 = primary.

## Performance bundle for ComfyUI ROCm

`patientx-cfz/comfyui-rocm` auto-installs:
- Triton (kernel JIT)
- Sage Attention (faster than xformers)
- Flash Attention (memory-bounded attention)
- bitsandbytes (4/8-bit quant ops)

Worth wiring into `install-comfyui.sh` as opt-in flag.

## What to skip

- **Speculative decoding** for MoE A3B (net-negative, see citations)
- **ZLUDA** (Windows only, Linux ROCm closes gap)
- **ik_llama.cpp** (CPU-focused fork, no ROCm support)
- **Ollama for big MoE** (no `--n-cpu-moe` equivalent — use llama-server)
- **70B+ dense models** until you're at 64GB RAM AND can sustain ~5 tok/s
- **Q8 GGUFs on Intel Arc** (4-5× slower than Q4_K_M due to kernel issue)

## Citations

- [Codacus: Running 35B on 6GB VRAM](https://www.youtube.com/watch?v=8F_5pdcD3HY)
- [HF blog: llama.cpp MoE offload guide](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide)
- [Medium: Qwen-3-235B-A22B partial offload](https://medium.com/@david.sanftenberg/gpu-poor-how-to-configure-offloading-for-the-qwen-3-235b-a22b-moe-model-using-llama-cpp-13dc15287bed)
- [llama.cpp #18049: MoE auto-tuning](https://github.com/ggml-org/llama.cpp/discussions/18049)
- [llama.cpp #15021: ROCm/HIP perf](https://github.com/ggml-org/llama.cpp/discussions/15021)
- [llama.cpp #15396: gpt-oss running guide](https://github.com/ggml-org/llama.cpp/discussions/15396)
- [Latent.Space: Top Local Models April 2026](https://www.latent.space/p/ainews-top-local-models-list-april)
- [HF: State of OS Spring 2026](https://huggingface.co/blog/huggingface/state-of-os-hf-spring-2026)
- [zolotukhin.ai: Why speculative decoding fails on A3B](https://zolotukhin.ai/blog/2026-04-28-why-speculative-decoding-does-not-net-out-on-qwen-35b-a3b/)
- [AMD blog: ComfyUI ROCm 7.1.1 5.4× uplift](https://www.amd.com/en/blogs/2026/amd-comfyui-advancing-professional-quality-generative-ai-ryzen-radeon.html)
- [patientx-cfz/comfyui-rocm](https://github.com/patientx-cfz/comfyui-rocm)
- [ROCm/TheRock #2679: Qwen3-Coder TPS on ROCm](https://github.com/ROCm/TheRock/issues/2679)
- [BentoML: Best open-source TTS 2026](https://www.bentoml.com/blog/exploring-the-world-of-open-source-text-to-speech-models)
- [siliconflow: Voice cloning models 2026](https://www.siliconflow.com/articles/en/best-open-source-models-for-voice-cloning)
- [siliconflow: Music generation 2026](https://www.siliconflow.com/articles/en/best-open-source-music-generation-models)
- [SoftwareSeni: Coding agent models comparison](https://www.softwareseni.com/qwen3-coder-next-deepseek-v3-2-and-glm-4-7-which-open-weight-model-wins-for-coding-agents/)
- [InsiderLLM: Best local coding models 2026](https://insiderllm.com/guides/best-local-coding-models-2026/)
- [unsloth Qwen3.5 docs](https://unsloth.ai/docs/models/qwen3.5)
- [Phoronix: R9700 review](https://www.phoronix.com/review/amd-radeon-ai-pro-r9700)
- [Phoronix: B70 review](https://www.phoronix.com/review/intel-arc-pro-b70-linux)
