#!/usr/bin/env bash
# ComfyUI + ROCm PyTorch + Wan 2.2 14B GGUF + post-processing
# Ubuntu Server 24.04, AMD 6900XT (gfx1030).
# Renderer for /opt/videogen pipeline.

set -euo pipefail

readonly INSTALL_DIR="/opt/comfyui"
readonly SERVICE_USER="comfy"
readonly PORT=8188
readonly LAN_CIDR="192.168.0.0/16"

# Auto-detect ROCm and pick matching PyTorch wheel index.
# Override with TORCH_INDEX_OVERRIDE env var if needed.
detect_rocm_version() {
    local v=""
    [[ -f /opt/rocm/.info/version ]] && v=$(< /opt/rocm/.info/version)
    if [[ -z "$v" ]]; then
        for d in /opt/rocm-*/; do
            [[ -f "${d}.info/version" ]] && { v=$(< "${d}.info/version"); break; }
        done
    fi
    if [[ -z "$v" ]] && command -v dpkg >/dev/null 2>&1; then
        local pkg
        pkg=$(dpkg -l 2>/dev/null | awk '$2 ~ /^hip-runtime-amd$/ {print $3}' | head -1)
        [[ -n "$pkg" ]] && v=$(echo "$pkg" | grep -oE '^[0-9]+\.[0-9]+')
    fi
    # NOTE: do NOT use rocminfo "Runtime Version" — that's HSA runtime, not ROCm SDK.
    echo "$v"
}

select_torch_index() {
    local rocm_ver="$1"
    local mm
    mm=$(echo "$rocm_ver" | cut -d. -f1-2)
    case "$mm" in
        6.2|6.3|6.4|7.0|7.1|7.2)
            echo "https://download.pytorch.org/whl/rocm${mm}" ;;
        7.3|7.4|7.5)
            echo "https://download.pytorch.org/whl/rocm7.2" ;;  # latest stable
        6.0|6.1)
            echo "https://download.pytorch.org/whl/rocm6.2" ;;  # closest forward
        5.*|"")
            echo "" ;;  # signal failure
        *)
            echo "https://download.pytorch.org/whl/rocm6.2" ;;
    esac
}

ROCM_VER="${ROCM_VER_OVERRIDE:-$(detect_rocm_version)}"
if [[ -z "$ROCM_VER" ]]; then
    echo "[X] ROCm not detected. Install it first or set ROCM_VER_OVERRIDE." >&2
    exit 1
fi
TORCH_INDEX="${TORCH_INDEX_OVERRIDE:-$(select_torch_index "$ROCM_VER")}"
if [[ -z "$TORCH_INDEX" ]]; then
    echo "[X] ROCm $ROCM_VER too old. Upgrade to 6.2+." >&2
    exit 1
fi
echo "[+] Detected ROCm: $ROCM_VER"
echo "[+] PyTorch wheel index: $TORCH_INDEX"
readonly TORCH_INDEX

# Default GGUF quant for Wan 2.2.
# 16GB system RAM -> Q4_K_M (safe). 32GB+ -> Q5_K_M. 64GB+ -> Q6_K.
readonly WAN_QUANT="${WAN_QUANT:-Q4_K_M}"

# LTX 2.3 22B: officially needs 128GB system RAM. Skip on low-RAM boxes.
# Set INSTALL_LTX=1 only after RAM upgrade to 64GB+.
readonly INSTALL_LTX="${INSTALL_LTX:-0}"

log() { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run with sudo."

# ---- system deps ----
log "System deps"
apt-get update
apt-get install -y --no-install-recommends \
    build-essential cmake git curl jq wget ca-certificates pkg-config \
    python3.11 python3.11-venv python3.11-dev python3-pip \
    ffmpeg libsndfile1 libgomp1 libgl1 libglib2.0-0 \
    nginx ufw aria2

# ---- service user ----
log "Service user '${SERVICE_USER}'"
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd -r -m -d /var/lib/${SERVICE_USER} -s /bin/bash "${SERVICE_USER}"
fi
usermod -aG video,render "${SERVICE_USER}"

# ---- clone ComfyUI ----
log "ComfyUI -> ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"
sudo -u "${SERVICE_USER}" bash <<EOF
set -euo pipefail
if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    git clone https://github.com/comfyanonymous/ComfyUI.git "${INSTALL_DIR}"
else
    git -C "${INSTALL_DIR}" pull --ff-only
fi
EOF

# ---- venv + ROCm torch ----
log "Python venv + ROCm PyTorch"
sudo -u "${SERVICE_USER}" bash <<EOF
set -euo pipefail
cd "${INSTALL_DIR}"
python3.11 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip wheel setuptools
pip install torch torchvision torchaudio --index-url ${TORCH_INDEX}
pip install -r requirements.txt
pip install --upgrade huggingface_hub hf_transfer
pip install gguf sentencepiece einops safetensors transformers accelerate "numpy<2.0"
EOF

# ---- custom nodes ----
log "Installing custom nodes"
NODES_DIR="${INSTALL_DIR}/custom_nodes"
sudo -u "${SERVICE_USER}" bash <<EOF
set -euo pipefail
mkdir -p "${NODES_DIR}"
cd "${NODES_DIR}"

clone_or_pull() {
    local url="\$1" dir="\$2"
    if [[ -d "\${dir}/.git" ]]; then
        git -C "\${dir}" pull --ff-only || true
    else
        git clone --depth=1 "\${url}" "\${dir}"
    fi
}

clone_or_pull https://github.com/ltdrdata/ComfyUI-Manager.git ComfyUI-Manager
clone_or_pull https://github.com/city96/ComfyUI-GGUF.git ComfyUI-GGUF
clone_or_pull https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git ComfyUI-VideoHelperSuite
clone_or_pull https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git ComfyUI-Frame-Interpolation
clone_or_pull https://github.com/kijai/ComfyUI-WanVideoWrapper.git ComfyUI-WanVideoWrapper
clone_or_pull https://github.com/cubiq/ComfyUI_essentials.git ComfyUI_essentials
clone_or_pull https://github.com/rgthree/rgthree-comfy.git rgthree-comfy
clone_or_pull https://github.com/ace-step/ComfyUI-ACE-Step.git ComfyUI-ACE-Step
clone_or_pull https://github.com/a-r-r-o-w/ComfyUI-MusicGen.git ComfyUI-MusicGen || true
# NAG node — boosts negative prompt at low CFG (turbo/distilled models)
clone_or_pull https://github.com/ChenDarYen/ComfyUI-NAG.git ComfyUI-NAG || true
# Hunyuan-Foley — add audio to existing Wan video clips
clone_or_pull https://github.com/if-ai/ComfyUI-IF_HunyuanFoley.git ComfyUI-IF_HunyuanFoley || true
# Civitai Helper — browse/download LoRAs from Civitai inside ComfyUI
clone_or_pull https://github.com/butaixianran/Stable-Diffusion-Webui-Civitai-Helper.git Civitai-Helper || true
clone_or_pull https://github.com/civitai/civitai-comfy-nodes.git civitai-comfy-nodes || true
# IndexTTS-2: zero-shot voice cloning + emotion control + duration control
clone_or_pull https://github.com/snicolast/ComfyUI-IndexTTS2.git ComfyUI-IndexTTS2 || true
# TTS Audio Suite: multi-engine TTS umbrella (Chatterbox, F5-TTS, etc)
clone_or_pull https://github.com/diodiogod/TTS-Audio-Suite.git TTS-Audio-Suite || true

# install per-node deps
source "${INSTALL_DIR}/.venv/bin/activate"
for d in */; do
    if [[ -f "\${d}requirements.txt" ]]; then
        echo "[deps] \${d}"
        pip install -r "\${d}requirements.txt" || true
    fi
done
EOF

# ---- model downloads ----
log "Downloading models (Wan 2.2 video, LTX-2 video, Flux Krea image, encoders, VAEs, upscalers)"
log "Total disk: ~70GB. Network: high. This takes a while."
MODELS_DIR="${INSTALL_DIR}/models"
sudo -u "${SERVICE_USER}" bash <<EOF
set -euo pipefail
cd "${INSTALL_DIR}"
source .venv/bin/activate
export HF_HUB_ENABLE_HF_TRANSFER=1

mkdir -p models/{diffusion_models,text_encoders,vae,clip_vision,upscale_models,unet,checkpoints,loras}

python - <<'PY'
import os, sys
from huggingface_hub import hf_hub_download

base = os.path.join(os.getcwd(), "models")
wan_quant = "${WAN_QUANT}"

def grab(repo, fname, subdir):
    target_dir = os.path.join(base, subdir)
    os.makedirs(target_dir, exist_ok=True)
    print(f"[get] {repo}::{fname} -> {subdir}")
    try:
        hf_hub_download(repo_id=repo, filename=fname, local_dir=target_dir, local_dir_use_symlinks=False)
        print("   ok")
    except Exception as e:
        print(f"   FAIL: {e}")

# ===== VIDEO: Wan 2.2 T2V-A14B GGUF (high + low noise experts) =====
grab("city96/Wan2.2-T2V-A14B-HighNoise-gguf", f"Wan2.2-T2V-A14B-HighNoise-{wan_quant}.gguf", "diffusion_models")
grab("city96/Wan2.2-T2V-A14B-LowNoise-gguf",  f"Wan2.2-T2V-A14B-LowNoise-{wan_quant}.gguf",  "diffusion_models")

# ===== VIDEO: Wan 2.2 I2V-A14B GGUF (for FLF2V stitching) =====
grab("city96/Wan2.2-I2V-A14B-HighNoise-gguf", f"Wan2.2-I2V-A14B-HighNoise-{wan_quant}.gguf", "diffusion_models")
grab("city96/Wan2.2-I2V-A14B-LowNoise-gguf",  f"Wan2.2-I2V-A14B-LowNoise-{wan_quant}.gguf",  "diffusion_models")

# ===== VIDEO: Wan 2.2 5B Turbo Q8 GGUF (native 1440p! per Tensor Alchemist) =====
# 4-step distilled. CFG=1, shift=5, SS solver, beta scheduler, NAG energy_scale=35.
grab("city96/Wan2.2-T2V-5B-Turbo-gguf", "Wan2.2-T2V-5B-Turbo-Q8_0.gguf", "diffusion_models")
# Lightning 4-step LoRA (often baked in; download separately as fallback)
grab("Kijai/WanVideo_comfy", "Wan2_2-Lightning-LoRA-rank32.safetensors", "loras")

# ===== VIDEO: LTX 2.3 v1.1 22B GGUF (gated on INSTALL_LTX, needs 64GB+ system RAM) =====
# v1.1 dropped late April 2026 (Tensor Alchemist breakdown):
#   big jumps in spatial awareness, lighting/shadow control, style adherence.
# Stick with GGUF on AMD (RDNA2 has no FP8 hardware, Sage Attention also unreliable).
if "${INSTALL_LTX}" == "1":
    for variant, fname in [
        ("LTX-Video-2.3-v1.1-T2V-GGUF", "ltx-video-2.3-v1.1-t2v-Q5_K_S.gguf"),
        ("LTX-Video-2.3-v1.1-I2V-GGUF", "ltx-video-2.3-v1.1-i2v-Q5_K_S.gguf"),
        # fallbacks if v1.1 repo names not yet posted with this exact path
        ("LTX-Video-2.3-T2V-GGUF",      "ltx-video-2.3-t2v-Q5_K_S.gguf"),
        ("LTX-Video-2.3-I2V-GGUF",      "ltx-video-2.3-i2v-Q5_K_S.gguf"),
    ]:
        for repo in [f"unsloth/{variant}", f"QuantStack/{variant}", f"Kijai/{variant}"]:
            try:
                grab(repo, fname, "diffusion_models")
                break
            except Exception:
                continue
    for repo in ["Lightricks/LTX-Video-2.3-v1.1", "Lightricks/LTX-Video-2.3", "Lightricks/LTX-Video"]:
        try:
            grab(repo, "ltxv-vae.safetensors", "vae")
            break
        except Exception:
            continue
else:
    print("[skip] LTX 2.3 v1.1 (set INSTALL_LTX=1 after 64GB+ system RAM upgrade)")

# ===== VIDEO LoRA: LTX 2.3 Lip-Sync LoRA (talking head w/ synced lips from voice) =====
# First community AV LoRA for LTX 2.3. End your prompt with the speech transcript.
if "${INSTALL_LTX}" == "1":
    for repo in [
        "Lightricks/LTXV-Lipsync-LoRA",
        "Kijai/LTX-Video-LipSync-LoRA",
    ]:
        try:
            grab(repo, "ltxv-lipsync-lora.safetensors", "loras")
            break
        except Exception:
            continue

# ===== AUDIO: Hunyuan-Foley (adds audio to Wan 2.2 video clips post-gen) =====
# Separate workflow to avoid OOM. ~2-3min/clip on 8GB. Strong on ambient sound.
grab("Tencent/HunyuanVideo-Foley", "hunyuan_video_foley.safetensors", "audio_models")

# ===== Wan video encoders/VAEs =====
grab("Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors", "text_encoders")
grab("Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/vae/wan_2.1_vae.safetensors", "vae")
grab("Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/clip_vision/clip_vision_h.safetensors", "clip_vision")

# ===== IMAGE: FLUX.2 Dev Q5_K_M GGUF (top-tier 2026 per benchmarks) =====
# Different stack from Flux 1: Mistral 3 Small as text encoder, new VAE.
grab("city96/FLUX.2-dev-gguf", "flux2-dev-Q5_K_M.gguf", "diffusion_models")
grab("Comfy-Org/Mistral-Small-Flux2",   "mistral_3_small_flux2_bf16.safetensors", "text_encoders")
grab("black-forest-labs/FLUX.2-dev",    "flux2-vae.safetensors", "vae")

# ===== IMAGE: Qwen-Image-2512 Q4_K_M GGUF (top OSS per Dec 2025 benchmarks) =====
# Alternative aesthetic to Flux family. Strong text rendering. Uses qwen text encoder.
grab("unsloth/Qwen-Image-2512-GGUF",     "Qwen-Image-2512-Q4_K_M.gguf", "diffusion_models")
grab("Comfy-Org/Qwen-Image_ComfyUI",     "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors", "text_encoders")
grab("Comfy-Org/Qwen-Image_ComfyUI",     "split_files/vae/qwen_image_vae.safetensors", "vae")

# ===== IMAGE: Flux.1 Krea Dev Q8 GGUF (skin specialist, anti-plastic) =====
grab("QuantStack/FLUX.1-Krea-dev-GGUF", "flux1-krea-dev-Q8_0.gguf", "diffusion_models")

# ===== IMAGE: Flux 1 text encoders + VAE (still needed for Krea) =====
grab("city96/t5-v1_1-xxl-encoder-gguf", "t5-v1_1-xxl-encoder-Q8_0.gguf", "text_encoders")
grab("comfyanonymous/flux_text_encoders", "clip_l.safetensors", "text_encoders")
grab("black-forest-labs/FLUX.1-schnell", "ae.safetensors", "vae")

# ===== IMAGE: SDXL base (fast iteration, storyboard refs, LoRA ecosystem) =====
grab("stabilityai/stable-diffusion-xl-base-1.0", "sd_xl_base_1.0.safetensors", "checkpoints")
grab("stabilityai/sdxl-vae", "sdxl_vae.safetensors", "vae")

# ===== Upscaler =====
grab("ai-forever/Real-ESRGAN", "RealESRGAN_x2.pth", "upscale_models")
grab("ai-forever/Real-ESRGAN", "RealESRGAN_x4.pth", "upscale_models")

# ===== MUSIC: ACE-Step 1.5 (AMD-tuned, <4GB VRAM, royalty-free trained) =====
os.makedirs(os.path.join(base, "audio_models"), exist_ok=True)
grab("ACE-Step/ACE-Step-v1-3.5B", "ace_step_v1_3.5b.safetensors", "audio_models")
grab("ACE-Step/ACE-Step-v1-3.5B", "config.json", "audio_models")

# ===== MUSIC: MusicGen Stereo (instrumental beats, primary for background music) =====
# Large = best quality for beats, ~7-8GB VRAM. Medium = lighter fallback ~3-4GB.
grab("facebook/musicgen-stereo-large", "model.safetensors", "audio_models")
grab("facebook/musicgen-stereo-medium", "model.safetensors", "audio_models")

# ===== TTS: IndexTTS-2 (zero-shot voice cloning + emotion control + duration) =====
# Complements GPT-SoVITS (which is fine-tune based). Use for varied narration tones.
os.makedirs(os.path.join(base, "TTS", "IndexTTS-2"), exist_ok=True)
for fname in [
    "config.yaml",
    "gpt.pth",
    "s2mel.pth",
    "wav2vec2bert_stats.pt",
    "qwen0.6bemo4-merge/config.json",
    "qwen0.6bemo4-merge/model.safetensors",
    "qwen0.6bemo4-merge/tokenizer.json",
]:
    try:
        grab("IndexTeam/IndexTTS-2", fname, "TTS/IndexTTS-2")
    except Exception:
        pass
PY

echo
echo "Disk usage by category:"
du -sh models/diffusion_models models/text_encoders models/vae models/checkpoints models/upscale_models 2>/dev/null || true
echo
echo "Total models dir:"
du -sh models 2>/dev/null || true
EOF

# ---- systemd unit ----
log "Systemd unit"
cat >/etc/systemd/system/comfyui.service <<EOF
[Unit]
Description=ComfyUI (ROCm, 6900XT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
SupplementaryGroups=video render
WorkingDirectory=${INSTALL_DIR}
Environment=PATH=${INSTALL_DIR}/.venv/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONUNBUFFERED=1
Environment=HSA_OVERRIDE_GFX_VERSION=10.3.0
Environment=PYTORCH_HIP_ALLOC_CONF=expandable_segments:True
Environment=HIP_VISIBLE_DEVICES=0
Environment=MIOPEN_FIND_MODE=FAST
ExecStart=${INSTALL_DIR}/.venv/bin/python main.py \\
    --listen 0.0.0.0 --port ${PORT} \\
    --use-pytorch-cross-attention \\
    --disable-smart-memory
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# ---- firewall ----
log "UFW (LAN only)"
if command -v ufw >/dev/null 2>&1; then
    ufw allow from "${LAN_CIDR}" to any port "${PORT}" proto tcp comment 'comfyui LAN' || true
fi

# ---- enable + start ----
log "Enable + start"
systemctl daemon-reload
systemctl enable --now comfyui

log "Wait for ComfyUI to come up"
for i in {1..60}; do
    if curl -fsS "http://127.0.0.1:${PORT}/system_stats" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

IP=$(hostname -I | awk '{print $1}')
cat <<EOF

============================================================
 ComfyUI up at http://${IP}:${PORT}

 Service:   systemctl status comfyui
 Logs:      journalctl -u comfyui -f
 Models:    ${INSTALL_DIR}/models/diffusion_models/

 Models installed (depending on env flags):
   VIDEO: Wan 2.2 14B ${WAN_QUANT} (T2V+I2V high+low noise experts) -- primary
          Wan 2.2 5B Turbo Q8 GGUF (native 1440p, 4-step turbo) -- fast iter
          LTX 2.3 v1.1 22B Q5_K_S (only if INSTALL_LTX=1; needs 64GB+ RAM)
          + LTX Lip-Sync LoRA (talking heads, only if INSTALL_LTX=1)
          + Wan Lightning 4-step LoRA
   IMAGE: FLUX.2 Dev Q5_K_M GGUF (top-tier 2026)
          Qwen-Image-2512 Q4_K_M GGUF (alt aesthetic, top OSS Dec 2025)
          Flux.1 Krea Dev Q8 GGUF (skin specialist)
          SDXL base + sdxl_vae (fast iter, LoRA library)
   IMAGE: Flux.1 Krea Dev Q8 GGUF (photoreal, fixes plastic skin)
          SDXL base (fast iteration, huge LoRA library)
   MUSIC: MusicGen Stereo Large (primary for beats, ~7-8GB VRAM)
          MusicGen Stereo Medium (lighter fallback, ~3-4GB VRAM)
          ACE-Step 1.5 3.5B (alt, full-song style, royalty-free)
   AUDIO: Hunyuan-Foley (add ambient/SFX to existing Wan clips post-gen)
   TTS:   IndexTTS-2 (zero-shot, emotion + duration control)
          [GPT-SoVITS v4 lives in /opt/GPT-SoVITS/, separate install]
   ENC:   umt5-xxl-fp8 (Wan), t5-v1_1-xxl-Q8 (Flux/LTX), clip_l, clip_vision_h
   VAE:   wan_2.1_vae, ltxv-vae, ae (Flux), sdxl_vae
   UPS:   Real-ESRGAN x2/x4

 Recommended workflow (per Mar 2026 benchmarks):
   * Prototype fast with LTX 2.3 (1-2 min/clip, has audio)
   * Refine motion-critical shots with Wan 2.2 (better physics, slower)

 Swap Wan quant: re-run with WAN_QUANT=Q6_K or Q8_0 env override.

 Note: LTX 2.3 prefers 128GB system RAM. With less RAM, expect swap on big jobs.
 Check yours: free -h

 First-time UI:
   1. Open http://${IP}:${PORT}
   2. Manager (top-right) -> Restart -> verify nodes load
   3. Drop any Wan 2.2 workflow JSON to test

 GPU env:  HSA_OVERRIDE_GFX_VERSION=10.3.0
 To free VRAM:  systemctl stop ollama gpt-sovits whisper
============================================================
EOF
