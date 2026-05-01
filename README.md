# llm-scripts

Local AI stack for Ubuntu Server 24.04 + AMD Radeon RX 6900 XT (16GB VRAM, gfx1030).

Full creative pipeline:

| Capability | Engine | Endpoint |
|---|---|---|
| **STT** (dictation) | whisper.cpp + Vulkan | `:9000` (OpenAI-compat) |
| **LLM** | Ollama (Qwen3 / GPT-OSS) | `:11434` (OpenAI-compat) |
| **TTS** (voice cloning) | GPT-SoVITS v4 | `:9874` (Gradio) |
| **Image gen** | ComfyUI + Flux Krea / SDXL | `:8188` |
| **Video gen** | ComfyUI + Wan 2.2 / LTX 2.3 | `:8188` |
| **Music gen** | ComfyUI + MusicGen / ACE-Step | `:8188` |
| **Orchestrator** | Justfile + Python pipeline | `/opt/videogen` |
| **Profiles** | Service-mode dispatcher | `profile <name>` |
| **Driver** | Claude Code | terminal/tmux |

## Install order (fresh box)

```bash
# 0a. Bootstrap (only on a fresh Ubuntu install — installs Vulkan, Ollama,
#     llama.cpp, Tailscale, helper aliases). Run as your user (NOT sudo).
./setup-machine-2-local-llms-server.sh

# 0b. Full ROCm SDK (required for ComfyUI + GPT-SoVITS PyTorch wheels).
#     Ollama's bundled mini-ROCm is NOT enough for diffusion models.
sudo ./install-rocm.sh
exec su - $USER   # re-login for groups + PATH

# 0c. Preflight — verify ROCm version, disk, RAM, ports, network
./preflight.sh

# 1. STT
sudo ./install-whisper-vulkan.sh

# 2. TTS
sudo ./install-gpt-sovits.sh

# 3. ComfyUI + models (~50GB, ~30-60min)
sudo ./install-comfyui.sh
# After RAM upgrade to 64GB+:
# INSTALL_LTX=1 WAN_QUANT=Q5_K_M sudo ./install-comfyui.sh

# 4. Pipeline orchestrator (/opt/videogen)
sudo ./install-videogen-pipeline.sh

# 5. Profile system (service stack switcher)
sudo ./install-profiles.sh

# 6. Claude Code (per-user, NOT sudo)
bash ./install-claude-code.sh

# 7. Reference workflow JSONs (run as videogen user)
sudo -iu videogen ~/bootstrap-workflows.sh
```

## Hardware tiering

VRAM is fixed at 16GB. RAM upgrades unlock model coexistence + bigger models.

| RAM | Headroom | What unlocks |
|---|---|---|
| 16GB now | One model at a time | Wan 2.2 Q4_K_M only, all else swaps |
| 32GB | Two services concurrent | Wan 2.2 Q5_K_M comfortable |
| 64GB | LTX 2.3 22B usable | Full pipeline coexistence |
| 128GB | Optimal | LTX 2.3 official spec |

## Profiles

```bash
profile list           # show all
profile status         # current + VRAM/RAM
profile dev            # whisper + qwen-coder:7b
profile dictate        # whisper + qwen3:7b
profile assistant      # full voice loop
profile chat-big       # gpt-oss:20b
profile moe-fast       # qwen3:30b-a3b MoE
profile video-fast     # ComfyUI LTX 2.3 (after 64GB RAM)
profile video-quality  # ComfyUI Wan 2.2
profile image          # ComfyUI Flux Krea / SDXL
profile train-tts      # GPT-SoVITS training
profile tts-bench      # GPT-SoVITS inference
profile music          # MusicGen / ACE-Step
profile music-light    # music + LLM + whisper
profile off            # idle, free all VRAM
```

## YouTube workflow

```bash
sudo -iu videogen
cd /opt/videogen
just new mythvid
just script mythvid "topic" 90        # Qwen drafts narration
just shots mythvid                    # split into shotlist

profile image
just thumbnail mythvid "<thumbnail prompt>"
just storyboard-imgs mythvid

profile video-quality
just render mythvid                   # ~10min/clip @ 480p
just interpolate mythvid              # 16->32fps
just upscale mythvid                  # -> 1080p

profile music-light
just music mythvid "boom bap, 90bpm, dusty drums" 90
just voice mythvid /path/to/ref.wav "transcript"

just mux mythvid                      # video + voice + ducked bgm + LUFS norm
```

Output: `/opt/videogen/projects/mythvid/final.mp4`

## Stack notes

- Wan 2.5/2.6 are **API-only** (audio licensing). Don't wait for weights.
- LTX 2.3 22B GGUF requires 64GB+ system RAM despite fitting 16GB VRAM.
- ROCm 7.2 (March 2026) drops `HSA_OVERRIDE_GFX_VERSION` requirement on RDNA3+. 6900XT (RDNA2) still needs override.
- All services are systemd-managed, LAN-firewalled (UFW).

## Files

| Script | What it installs |
|---|---|
| `install-whisper-vulkan.sh` | whisper.cpp Vulkan + nginx OpenAI shim + systemd |
| `install-gpt-sovits.sh` | GPT-SoVITS v4 + ROCm PyTorch + Gradio webui + systemd |
| `install-comfyui.sh` | ComfyUI + ROCm + Wan 2.2 + LTX 2.3 (gated) + Flux Krea + SDXL + ACE-Step + MusicGen + Real-ESRGAN |
| `install-videogen-pipeline.sh` | `/opt/videogen` skeleton + Justfile + 10 Python stages + smart mux |
| `install-profiles.sh` | `/usr/local/bin/profile` dispatcher + 12 default profiles |
| `install-claude-code.sh` | nvm + Node 20 + Claude Code + tmux launcher + server-aware CLAUDE.md |
| `bootstrap-workflows.sh` | Pulls reference ComfyUI workflow JSONs, injects placeholders |

## License

MIT (or whatever you want — these are install scripts).
