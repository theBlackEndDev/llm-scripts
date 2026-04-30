#!/usr/bin/env bash
# Claude Code on Ubuntu Server 24.04
# Installs Node 20 LTS via nvm, Claude Code, sets up tmux session helper,
# and seeds ~/.claude/CLAUDE.md with the local AI stack context.

set -euo pipefail

# Run as your interactive user (NOT sudo). Creates per-user install.
if [[ $EUID -eq 0 ]]; then
    echo "Run as your normal login user, not sudo."
    echo "  bash install-claude-code.sh"
    exit 1
fi

USER_HOME="${HOME}"

log() { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }

# ---- system deps (sudo for these only) ----
log "System deps (will prompt for sudo password)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    curl ca-certificates git tmux build-essential

# ---- nvm + Node 20 ----
if [[ ! -d "${USER_HOME}/.nvm" ]]; then
    log "Installing nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi

# load nvm into this shell
export NVM_DIR="${USER_HOME}/.nvm"
# shellcheck disable=SC1091
source "${NVM_DIR}/nvm.sh"

log "Installing Node 20 LTS"
nvm install 20
nvm alias default 20
nvm use default

log "Installing Claude Code globally via npm"
npm install -g @anthropic-ai/claude-code

# ---- tmux helper ----
log "tmux launcher: ~/bin/cc"
mkdir -p "${USER_HOME}/bin"
cat >"${USER_HOME}/bin/cc" <<'BASH'
#!/usr/bin/env bash
# Reattach to or start a persistent Claude Code tmux session.
SESSION="${1:-claude}"
if tmux has-session -t "${SESSION}" 2>/dev/null; then
    exec tmux attach -t "${SESSION}"
fi
exec tmux new-session -s "${SESSION}" "claude"
BASH
chmod +x "${USER_HOME}/bin/cc"

# ensure ~/bin on PATH
if ! grep -q 'HOME/bin' "${USER_HOME}/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "${USER_HOME}/.bashrc"
fi

# ---- server-aware CLAUDE.md ----
log "Writing ~/.claude/CLAUDE.md (server context)"
mkdir -p "${USER_HOME}/.claude"
cat >"${USER_HOME}/.claude/CLAUDE.md" <<'MD'
# Server: hustle-llm — local AI stack

This box is an Ubuntu 24.04 server with an AMD Radeon RX 6900 XT (16GB, gfx1030) used for local AI workloads. ROCm + Vulkan installed. Treat it as the orchestrator for STT, TTS, LLM, and video generation.

## Services on this box

| Service        | Unit            | Port  | Backend                | VRAM idle | VRAM active |
|----------------|-----------------|-------|------------------------|-----------|-------------|
| Ollama (Qwen)  | ollama          | 11434 | ROCm                   | ~6 GB     | ~7 GB       |
| whisper.cpp    | whisper         | 9000  | Vulkan                 | ~0.3 GB   | ~1.5 GB     |
| GPT-SoVITS v4  | gpt-sovits      | 9874  | ROCm (Gradio)          | ~0.5 GB   | ~10 GB train|
| ComfyUI        | comfyui         | 8188  | ROCm                   | ~0.2 GB   | ~14 GB      |

OpenAI-compatible endpoints:
- whisper.cpp: `POST http://127.0.0.1:9000/v1/audio/transcriptions`
- Ollama:      `POST http://127.0.0.1:11434/v1/chat/completions`

## VRAM budget

Total: 16 GB. Concurrent steady-state max: Ollama + whisper = ~7 GB. ComfyUI rendering needs ~14 GB → run `just stop` to free Ollama/SoVITS/Whisper before big renders. Use `rocm-smi` to inspect.

## Generative model stack (April 2026 state)

**System constraint right now: 16GB system RAM.** Limits us to one model loaded at a time and small/medium quants. Re-tier the stack as RAM grows.

**Video (open weights — Wan 2.5/2.6 are API-only, ignore):**
- **Wan 2.2 14B Q4_K_M GGUF** — PRIMARY now (16GB RAM). Best motion realism. ~9GB file.
- **Wan 2.2 14B Q5_K_M** — bump to this after 32GB RAM upgrade.
- **LTX 2.3 v1.1 22B Q5_K_S** — DEFER until 64GB+ RAM. Native audio + 5.7x speedup. v1.1 (April 2026) is big improvement over base 2.3 in lighting, spatial awareness, style adherence. Re-run install-comfyui.sh with `INSTALL_LTX=1` after upgrade.

**LTX 2.3 v1.1 prompting notes (per Tensor Alchemist breakdown):**
- *Strong:* lighting/mood (blue hour, deep shadows), architectural prompts (specific window types), style (anime stays 2D), single-subject motion, slow camera moves
- *Weak:* fingers melting into objects, big camera zooms on faces, fast multi-stage action, object permanence on motion, instant-shoe-appearance-on-landing
- *Workarounds:* keep camera distant for movement scenes, single-subject focus, slower action, cut at weak moments
- *On AMD 6900XT:* always GGUF (no FP8 hw, no Sage Attention support). Don't waste time on FP8 path.
- *Order:* always interpolate FIRST, THEN upscale. Reverse = OOM on 16GB system RAM.

**Image:**
- **Flux.1 Krea Dev Q5/Q8 GGUF** — photoreal, fixes "plastic skin"
- **SDXL** — fast iteration, huge LoRA library

**Music (background beats):**
- **MusicGen Stereo Large** — primary for beats/instrumental beds (~7-8GB VRAM). Designed for instrumental, supports loops/extension, melody conditioning.
- **MusicGen Stereo Medium** — lighter fallback (~3-4GB VRAM).
- **ACE-Step 1.5** — alt, full-song style with optional vocals (~4GB VRAM, royalty-free training).

For YouTube background beats: default `just music` uses MusicGen. Pass `ace` as 4th arg only when you want full-song structure with vocals.

**Strict rule on 16GB system RAM:** run `just stop` to kill ollama/sovits/whisper before any render. Only one diffusion model at a time. Don't leave ComfyUI loaded with multiple models.

`free -h` should show >4GB available before queuing a render.

## Video generation pipeline

Lives at `/opt/videogen/`. Runs as user `videogen`. Justfile-driven.

```
sudo -iu videogen
cd /opt/videogen
just                                  # list commands
just new <slug>
just script <slug> "topic" 90         # Qwen drafts narration
just shots <slug>                     # split into shotlist (TOML)
just stop                             # free VRAM
just storyboard-imgs <slug>           # Flux Krea generates ref stills (optional, recommended)
just render <slug>                    # ComfyUI Wan 2.2 chain (uses stills as I2V if present)
just interpolate <slug>               # 16->32fps
just upscale <slug>                   # -> 1080p
just voice <slug> <ref_wav> "ref"     # GPT-SoVITS narration
just music <slug> "<prompt>" 60       # ACE-Step background track (60s)
just mux <slug>                       # -> projects/<slug>/final.mp4 (mixes voice+music)
just thumbnail <slug> "<prompt>"      # YouTube thumbnail via Flux Krea
just all-img <slug>                   # storyboard-imgs + render + interp + upscale + mux
just start                            # restart services
```

Workflows in `/opt/videogen/workflows/`:
- `wan22_t2v.json`, `wan22_i2v.json`, `wan22_flf2v.json` — primary video (Wan 2.2)
- `ltx23_t2v.json`, `ltx23_i2v.json` — present only if LTX installed (post 64GB RAM)
- `flux_krea_t2i.json`, `sdxl_t2i.json` — image gen

## Bootstrap / repair workflows

If any workflow JSON is broken or a placeholder, run `~/bootstrap-workflows.sh` (as videogen user). It pulls reference workflows from official ComfyUI examples + Kijai/Lightricks repos, then injects placeholders (`__PROMPT__`, `__SEED__`, `__WIDTH__`, `__HEIGHT__`, `__FRAMES__`, `__FPS__`).

If a model expects a specific node Claude doesn't recognize, drive ComfyUI directly:
1. `curl http://127.0.0.1:8188/object_info` — list all available nodes + their schemas.
2. Build workflow JSON node-by-node referencing that schema.
3. POST to `/prompt` with `{prompt: <wf>, client_id: <uuid>}`. Watch `/ws` for completion.
4. If a node errors, `journalctl -u comfyui -n 50` for the stack trace.
5. Iterate until queue succeeds, then save the final JSON to `/opt/videogen/workflows/`.

For tricky workflows (LTX 2.3 three-sampler, Wan 2.2 dual-expert), prefer to download a community example from the model author's HF repo or kijai's repos rather than building from scratch.

ComfyUI API Format JSON with placeholders: `__PROMPT__`, `__SEED__`, `__FRAMES__`, `__WIDTH__`, `__HEIGHT__`, `__FPS__`, `__FIRST_FRAME__`.

Render defaults: 832x480, 16fps, Q5_K_M GGUF (FoxtonAI Aug 2025 sweet spot for 16GB cards, validated). Post-process: minterpolate 16→32fps, lanczos upscale to 1080p.

**Image-first workflow beats pure T2V**: generate a still per shot with Flux Krea, feed into Wan 2.2 I2V → cleaner motion, better composition. Use `just all-img` for this path.

## When user says "render a video about X"

1. `sudo -iu videogen` if not already.
2. Pick slug (kebab-case).
3. `just new <slug>`.
4. `just script <slug> "<topic>" <seconds>` — drafts via Qwen.
5. Read `projects/<slug>/script.md`. Edit if needed.
6. `just shots <slug>` — drafts shotlist as TOML.
7. Read `projects/<slug>/shots.toml`. Edit prompts to be visually concrete (no dialogue, no on-screen text — Wan butchers text).
8. `just stop` — free VRAM.
9. (Optional, recommended) `just storyboard-imgs <slug>` — Flux Krea ref stills. Each ~30-60s.
10. `just render <slug>` — long. Each 5s shot ≈ 7-12min @ 480p.
11. Spot-check `projects/<slug>/01_clips/`. Regen weak shots: `just render <slug> 03`.
12. `just interpolate <slug> && just upscale <slug>`.
13. If voice: ensure GPT-SoVITS api_v2 is running, then `just voice ...`.
14. `just mux <slug>`. Open `projects/<slug>/final.mp4`.
15. `just thumbnail <slug> "<thumbnail prompt>"` for the YouTube cover.
16. `just start` — restore services.

## When user says "generate an image of X"

1. `sudo -iu videogen` (or use comfyui directly via http://SERVER:8188).
2. `just thumbnail <project> "<prompt>"` — uses Flux Krea by default.
3. Or set 4th arg to `sdxl` for fast SDXL iteration.
4. Output: `projects/<slug>/thumbnails/thumbnail.png`.

## Conventions

- Always check `rocm-smi` before launching renders.
- Long renders → use `tmux` so the session survives ssh disconnect.
- Prompts: short, concrete, single subject, single action. Avoid 2+ moving subjects.
- Don't ask Wan for legible text in video. Add captions in post.
- For long videos: chain via FLF2V (last frame of clip N → first frame of clip N+1).

## Profile system

Switch service stacks for the workflow you're doing. `profile <name>` stops conflicting services, starts needed ones, optionally preloads an Ollama model.

```bash
profile list           # show all
profile status         # current + VRAM/RAM
profile dev            # whisper + small coding LLM
profile dictate        # whisper + LLM cleanup
profile assistant      # voice loop (STT+LLM+TTS)
profile chat-big       # GPT-OSS 20B Q4 only
profile moe-fast       # Qwen 3.6 35B-A3B MoE
profile video-fast     # ComfyUI LTX 2.3 (after 64GB RAM)
profile video-quality  # ComfyUI Wan 2.2
profile image          # ComfyUI Flux Krea / SDXL
profile train-tts      # GPT-SoVITS training
profile tts-bench      # GPT-SoVITS inference + LLM
profile music          # ACE-Step / MusicGen via ComfyUI (low VRAM)
profile music-light    # music + LLM + whisper (creative loop)
profile off            # idle, free all VRAM
```

When user asks for a workflow, switch to the right profile first, then act.

## Useful commands

```bash
rocm-smi                          # GPU usage
journalctl -u comfyui -f          # render logs
ss -ltnp | grep -E '8188|9000|9874|11434'   # who's listening
df -h /opt                        # disk: models eat ~50GB+
free -h                           # RAM (LTX 2.3 needs 64GB+)
profile status                    # what's currently running
```
MD

# ---- printable summary ----
NODE_VER=$(node -v 2>/dev/null || echo "?")
NPM_VER=$(npm -v 2>/dev/null || echo "?")
CC_VER=$(claude --version 2>/dev/null || echo "?")

cat <<EOF

============================================================
 Claude Code installed.

   node:    ${NODE_VER}
   npm:     ${NPM_VER}
   claude:  ${CC_VER}

 First run (browser device-code auth):
   claude

 Persistent tmux session (recommended):
   cc          # alias installed at ~/bin/cc
   # detach: Ctrl-b d
   # reattach: cc

 Server context written to:
   ~/.claude/CLAUDE.md

 To use it:
   1. Open a new shell (or 'source ~/.bashrc') so PATH picks up nvm + ~/bin
   2. cd /opt/videogen   (or anywhere)
   3. cc                 # opens claude in tmux
   4. Ask: "Render me a 90-second video about X"
============================================================
EOF
