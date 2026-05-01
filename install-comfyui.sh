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
    python3 python3-venv python3-dev python3-pip \
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
    git clone https://github.com/comfyanonymous/ComfyUI.git "${INSTALL_DIR}" || \
        git clone https://github.com/Comfy-Org/ComfyUI.git "${INSTALL_DIR}"
else
    git -C "${INSTALL_DIR}" pull --ff-only
fi
EOF

# ---- venv + ROCm torch ----
log "Python venv + ROCm PyTorch"
sudo -u "${SERVICE_USER}" bash <<EOF
set -euo pipefail
cd "${INSTALL_DIR}"
python3 -m venv .venv
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

# Core ComfyUI ecosystem (verified repos)
clone_or_pull https://github.com/Comfy-Org/ComfyUI-Manager.git ComfyUI-Manager
clone_or_pull https://github.com/city96/ComfyUI-GGUF.git ComfyUI-GGUF
clone_or_pull https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git ComfyUI-VideoHelperSuite
clone_or_pull https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git ComfyUI-Frame-Interpolation
clone_or_pull https://github.com/kijai/ComfyUI-WanVideoWrapper.git ComfyUI-WanVideoWrapper
clone_or_pull https://github.com/cubiq/ComfyUI_essentials.git ComfyUI_essentials
clone_or_pull https://github.com/rgthree/rgthree-comfy.git rgthree-comfy
clone_or_pull https://github.com/ChenDarYen/ComfyUI-NAG.git ComfyUI-NAG || true

# Music gen
clone_or_pull https://github.com/billwuhao/ComfyUI_ACE-Step.git ComfyUI_ACE-Step || true
clone_or_pull https://github.com/eigenpunk/ComfyUI-audio.git ComfyUI-audio || true

# Audio post (Hunyuan-Foley)
clone_or_pull https://github.com/aistudynow/Comfyui-HunyuanFoley.git Comfyui-HunyuanFoley || true

# Civitai LoRA browser (verified — old butaixianran repo is SD-WebUI not ComfyUI)
clone_or_pull https://github.com/MoonGoblinDev/Civicomfy.git Civicomfy || true

# TTS
clone_or_pull https://github.com/snicolast/ComfyUI-IndexTTS2.git ComfyUI-IndexTTS2 || true
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
log "Downloading models (Wan 2.2, LTX, Flux 2, Krea, Qwen-Image, SDXL, MusicGen, ACE-Step, Foley, IndexTTS-2)"
log "Total disk: ~80-100GB. Network: high. This takes a while."
log "If you have an HF_TOKEN env set, it will be used for any gated repos."
MODELS_DIR="${INSTALL_DIR}/models"
sudo -u "${SERVICE_USER}" --preserve-env=HF_TOKEN,HUGGING_FACE_HUB_TOKEN bash <<EOF
set -euo pipefail
cd "${INSTALL_DIR}"
source .venv/bin/activate
export HF_HUB_ENABLE_HF_TRANSFER=1

mkdir -p models/{diffusion_models,text_encoders,vae,clip_vision,upscale_models,unet,checkpoints,loras,audio_models,TTS}

python - <<'PY'
import os, sys, traceback
from huggingface_hub import hf_hub_download, snapshot_download

base = os.path.join(os.getcwd(), "models")
wan_quant = "${WAN_QUANT}"
hf_token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
install_ltx = "${INSTALL_LTX}" == "1"

ok_count = 0
fail_count = 0
fails = []

def grab(repo, fname, subdir, gated=False):
    global ok_count, fail_count
    target_dir = os.path.join(base, subdir)
    os.makedirs(target_dir, exist_ok=True)
    target = os.path.join(target_dir, os.path.basename(fname))
    if os.path.exists(target) and os.path.getsize(target) > 0:
        print(f"[skip] already have {fname}")
        ok_count += 1
        return True
    print(f"[get] {repo}::{fname} -> {subdir}")
    try:
        kwargs = dict(repo_id=repo, filename=fname, local_dir=target_dir,
                      local_dir_use_symlinks=False)
        if hf_token: kwargs["token"] = hf_token
        hf_hub_download(**kwargs)
        # Verify
        candidate = os.path.join(target_dir, fname.split("/")[-1])
        if os.path.exists(candidate) and os.path.getsize(candidate) > 1024:
            print(f"   ok ({os.path.getsize(candidate)//(1024*1024)}MB)")
            ok_count += 1
            return True
        else:
            print(f"   FAIL: file missing or zero-size after download")
            fails.append(f"{repo}::{fname}")
            fail_count += 1
            return False
    except Exception as e:
        msg = str(e)[:200]
        if gated and ("401" in msg or "403" in msg or "gated" in msg.lower()):
            print(f"   GATED: needs HF_TOKEN with license accepted. Skipping.")
        else:
            print(f"   FAIL: {msg}")
        fails.append(f"{repo}::{fname}")
        fail_count += 1
        return False

def grab_snapshot(repo, subdir, allow_patterns=None):
    global ok_count, fail_count
    target_dir = os.path.join(base, subdir)
    os.makedirs(target_dir, exist_ok=True)
    print(f"[snapshot] {repo} -> {subdir}")
    try:
        kwargs = dict(repo_id=repo, local_dir=target_dir,
                      local_dir_use_symlinks=False, max_workers=4)
        if allow_patterns: kwargs["allow_patterns"] = allow_patterns
        if hf_token: kwargs["token"] = hf_token
        snapshot_download(**kwargs)
        print(f"   ok")
        ok_count += 1
    except Exception as e:
        print(f"   FAIL: {str(e)[:200]}")
        fails.append(f"snapshot:{repo}")
        fail_count += 1

# ===== VIDEO: Wan 2.2 GGUF (QuantStack, real repo, structure: HighNoise/ + LowNoise/) =====
for noise in ["HighNoise", "LowNoise"]:
    grab("QuantStack/Wan2.2-T2V-A14B-GGUF",
         f"{noise}/Wan2.2-T2V-A14B-{noise}-{wan_quant}.gguf", "diffusion_models")
    grab("QuantStack/Wan2.2-I2V-A14B-GGUF",
         f"{noise}/Wan2.2-I2V-A14B-{noise}-{wan_quant}.gguf", "diffusion_models")

# Wan 2.2 TI2V-5B (native 1440p, distilled in single model)
grab("QuantStack/Wan2.2-TI2V-5B-GGUF",
     f"Wan2.2-TI2V-5B-{wan_quant}.gguf", "diffusion_models")

# Wan 2.2 official ComfyUI repackage: encoder, VAE, lightning 4-step LoRAs
WAN_REPACK = "Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
grab(WAN_REPACK, "split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors", "text_encoders")
grab(WAN_REPACK, "split_files/vae/wan2.2_vae.safetensors",       "vae")
grab(WAN_REPACK, "split_files/vae/wan_2.1_vae.safetensors",      "vae")  # fallback for older workflows
grab(WAN_REPACK, "split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors", "loras")
grab(WAN_REPACK, "split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors",  "loras")
grab(WAN_REPACK, "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors",   "loras")
grab(WAN_REPACK, "split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors",    "loras")

# CLIP-Vision (for I2V conditioning) — from older Wan 2.1 repackage
grab("Comfy-Org/Wan_2.1_ComfyUI_repackaged",
     "split_files/clip_vision/clip_vision_h.safetensors", "clip_vision")

# ===== VIDEO: LTX 2.3 (gated on INSTALL_LTX, needs 64GB+ RAM) =====
if install_ltx:
    print("[info] LTX 2.3 install gated on — fetching")
    # Repos may shift; try multiple fallback names
    for repo in [
        "Lightricks/LTX-Video",
        "Lightricks/LTXV",
    ]:
        try:
            grab_snapshot(repo, "diffusion_models/ltx",
                          allow_patterns=["*.safetensors", "*.pth", "*.json", "*.yaml"])
            break
        except Exception:
            continue
else:
    print("[skip] LTX 2.3 (set INSTALL_LTX=1 after 64GB+ RAM upgrade)")

# ===== AUDIO: Hunyuan-Foley (adds audio to Wan 2.2 video clips) =====
for fname in ["hunyuanvideo_foley.pth",
              "synchformer_state_dict.pth",
              "vae_128d_48k.pth",
              "config.yaml"]:
    grab("tencent/HunyuanVideo-Foley", fname, "audio_models/HunyuanFoley")

# ===== IMAGE: FLUX.2 Dev (Comfy-Org repackage has encoder + VAE; GGUF for diffusion) =====
grab("city96/FLUX.2-dev-gguf",   "flux2-dev-Q5_K_M.gguf", "diffusion_models")
grab("Comfy-Org/flux2-dev",      "split_files/text_encoders/mistral_3_small_flux2_fp8.safetensors", "text_encoders")
grab("Comfy-Org/flux2-dev",      "split_files/vae/flux2-vae.safetensors", "vae")
grab("Comfy-Org/flux2-dev",      "split_files/loras/Flux2TurboComfyv2.safetensors", "loras")

# ===== IMAGE: Qwen-Image-2512 (lowercase filenames per actual repo) =====
grab("unsloth/Qwen-Image-2512-GGUF",  "qwen-image-2512-Q4_K_M.gguf", "diffusion_models")
grab("Comfy-Org/Qwen-Image_ComfyUI",  "split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors", "text_encoders")
grab("Comfy-Org/Qwen-Image_ComfyUI",  "split_files/vae/qwen_image_vae.safetensors", "vae")

# ===== IMAGE: Flux.1 Krea Dev (skin specialist) =====
grab("QuantStack/FLUX.1-Krea-dev-GGUF",   "flux1-krea-dev-Q8_0.gguf", "diffusion_models")
grab("city96/t5-v1_1-xxl-encoder-gguf",   "t5-v1_1-xxl-encoder-Q8_0.gguf", "text_encoders")
grab("comfyanonymous/flux_text_encoders", "clip_l.safetensors", "text_encoders")
# Public ae.safetensors mirror (avoids gated black-forest-labs/FLUX.1-schnell)
grab("sirorable/flux-ae-vae", "ae.safetensors", "vae")

# ===== IMAGE: SDXL =====
grab("stabilityai/stable-diffusion-xl-base-1.0", "sd_xl_base_1.0.safetensors", "checkpoints")
grab("stabilityai/sdxl-vae", "sdxl_vae.safetensors", "vae")

# ===== Upscalers =====
grab("ai-forever/Real-ESRGAN", "RealESRGAN_x2.pth", "upscale_models")
grab("ai-forever/Real-ESRGAN", "RealESRGAN_x4.pth", "upscale_models")

# ===== MUSIC: ACE-Step 1.5 (multi-file structure — snapshot the whole repo) =====
grab_snapshot("ACE-Step/ACE-Step-v1-3.5B", "audio_models/ACE-Step",
              allow_patterns=["*.json", "*.safetensors"])

# ===== MUSIC: MusicGen Stereo =====
grab("facebook/musicgen-stereo-large",  "model.safetensors", "audio_models/musicgen-stereo-large")
grab("facebook/musicgen-stereo-medium", "model.safetensors", "audio_models/musicgen-stereo-medium")

# ===== TTS: IndexTTS-2 (snapshot whole repo) =====
grab_snapshot("IndexTeam/IndexTTS-2", "TTS/IndexTTS-2",
              allow_patterns=["*.yaml", "*.pth", "*.pt", "*.model", "*.txt",
                              "qwen0.6bemo4-merge/*"])

# ===== Summary =====
print()
print("=" * 50)
print(f"Downloads OK:    {ok_count}")
print(f"Downloads FAIL:  {fail_count}")
if fails:
    print("Failed:")
    for f in fails[:20]:
        print(f"  - {f}")
    print()
    print("Failures usually mean: gated repo (set HF_TOKEN), file renamed,")
    print("or transient network. Re-run install-comfyui.sh — successful files skip.")
print("=" * 50)
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
