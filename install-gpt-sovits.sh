#!/usr/bin/env bash
# GPT-SoVITS v2 — Ubuntu Server 24.04 + AMD 6900XT (ROCm)
# Installs training + inference WebUI, runs as systemd service.
# WebUI: http://HOST:9874  (main, training)
# Inference UI launched from main WebUI on 9872.

set -euo pipefail

readonly INSTALL_DIR="/opt/GPT-SoVITS"
readonly SERVICE_USER="sovits"
readonly WEBUI_PORT=9874
readonly LAN_CIDR="192.168.0.0/16"
readonly REPO_URL="https://github.com/RVC-Boss/GPT-SoVITS.git"
readonly TORCH_INDEX="https://download.pytorch.org/whl/rocm6.2"
readonly HF_REPO="lj1995/GPT-SoVITS"

log() { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run with sudo."

log "System deps"
apt-get update
apt-get install -y --no-install-recommends \
    build-essential cmake git curl jq wget ca-certificates pkg-config \
    python3.11 python3.11-venv python3.11-dev python3-pip \
    ffmpeg libsndfile1 libgomp1 \
    nginx ufw

log "Service user"
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd -r -m -d /var/lib/${SERVICE_USER} -s /bin/bash "${SERVICE_USER}"
fi
usermod -aG video,render "${SERVICE_USER}"

log "Cloning GPT-SoVITS -> ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
chown "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"
if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    sudo -u "${SERVICE_USER}" git clone --depth=1 "${REPO_URL}" "${INSTALL_DIR}"
else
    sudo -u "${SERVICE_USER}" git -C "${INSTALL_DIR}" pull --ff-only
fi

log "Python venv + ROCm PyTorch"
sudo -u "${SERVICE_USER}" bash <<EOF
set -euo pipefail
cd "${INSTALL_DIR}"
python3.11 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip wheel setuptools

# ROCm PyTorch (AMD)
pip install torch torchvision torchaudio --index-url ${TORCH_INDEX}

# Repo deps
if [[ -f requirements.txt ]]; then
    pip install -r requirements.txt
fi
if [[ -f extra-req.txt ]]; then
    pip install -r extra-req.txt || true
fi

# Common extras GPT-SoVITS expects
pip install \
    "huggingface_hub>=0.23" \
    modelscope \
    funasr \
    faster-whisper \
    gradio \
    "numpy<2.0" \
    soundfile librosa pyloudnorm \
    onnxruntime
EOF

log "Downloading pretrained models (v1-v4) from HuggingFace (${HF_REPO})"
sudo -u "${SERVICE_USER}" bash <<EOF
set -euo pipefail
cd "${INSTALL_DIR}"
source .venv/bin/activate
mkdir -p GPT_SoVITS/pretrained_models tools/asr/models tools/uvr5/uvr5_weights
export HF_HUB_ENABLE_HF_TRANSFER=1
pip install -q hf_transfer || true
python - <<'PY'
from huggingface_hub import snapshot_download
import os

base = os.getcwd()

# Full pretrained set (includes v1, v2, v3, v4 subfolders)
snapshot_download(
    repo_id="lj1995/GPT-SoVITS",
    local_dir=os.path.join(base, "GPT_SoVITS", "pretrained_models"),
    local_dir_use_symlinks=False,
    max_workers=8,
)
print("[ok] pretrained_models")

# ASR models (faster-whisper large-v3 used by v4 recipe)
try:
    snapshot_download(
        repo_id="Systran/faster-whisper-large-v3",
        local_dir=os.path.join(base, "tools", "asr", "models", "faster-whisper-large-v3"),
        local_dir_use_symlinks=False,
        max_workers=8,
    )
    print("[ok] faster-whisper-large-v3")
except Exception as e:
    print("[warn] faster-whisper download skipped:", e)
PY

# Verify v4 weights present
V4_DIR="GPT_SoVITS/pretrained_models/gsv-v4-pretrained"
if [[ -d "\${V4_DIR}" ]]; then
    echo "[ok] v4 weights at \${V4_DIR}"
    ls "\${V4_DIR}"
else
    echo "[warn] v4 subfolder not found; check HF repo layout"
fi
EOF

log "Patching webui to bind 0.0.0.0"
WEBUI_FILE="${INSTALL_DIR}/webui.py"
if [[ -f "${WEBUI_FILE}" ]]; then
    sudo -u "${SERVICE_USER}" sed -i \
        -e 's/server_name="127.0.0.1"/server_name="0.0.0.0"/g' \
        -e 's/share=True/share=False/g' \
        "${WEBUI_FILE}" || true
fi

log "Systemd unit"
cat >/etc/systemd/system/gpt-sovits.service <<EOF
[Unit]
Description=GPT-SoVITS WebUI (training + inference)
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
Environment=GRADIO_SERVER_NAME=0.0.0.0
Environment=GRADIO_SERVER_PORT=${WEBUI_PORT}
Environment=is_share=False
ExecStart=${INSTALL_DIR}/.venv/bin/python webui.py en_US
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

log "Nginx reverse proxy on :${WEBUI_PORT} (websocket-ready for Gradio)"
cat >/etc/nginx/sites-available/gpt-sovits <<EOF
server {
    listen ${WEBUI_PORT};
    listen [::]:${WEBUI_PORT};
    server_name _;

    client_max_body_size 4G;
    proxy_read_timeout  3600s;
    proxy_send_timeout  3600s;

    location / {
        proxy_pass http://127.0.0.1:${WEBUI_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
EOF
# Note: gradio binds to ${WEBUI_PORT} directly; nginx not strictly required.
# Skipping symlink to avoid double-bind. Uncomment to put nginx in front:
# ln -sf /etc/nginx/sites-available/gpt-sovits /etc/nginx/sites-enabled/gpt-sovits

log "UFW (LAN only)"
if command -v ufw >/dev/null 2>&1; then
    for p in 9871 9872 9873 ${WEBUI_PORT}; do
        ufw allow from "${LAN_CIDR}" to any port ${p} proto tcp comment "gpt-sovits ${p}" || true
    done
fi

log "Enable + start"
systemctl daemon-reload
systemctl enable --now gpt-sovits

log "Waiting for WebUI"
for i in {1..30}; do
    if curl -fsS "http://127.0.0.1:${WEBUI_PORT}/" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

IP=$(hostname -I | awk '{print $1}')
cat <<EOF

============================================================
 GPT-SoVITS v4 WebUI up.

 Service:    systemctl status gpt-sovits
 Logs:       journalctl -u gpt-sovits -f
 WebUI:      http://${IP}:${WEBUI_PORT}

 Ports (auto-launched from main UI):
   9871  SubFix annotation
   9872  TTS inference UI
   9873  UVR5 vocal separation

 ----- Use v4 -----
 1. Top of WebUI: pick "v4" in version dropdown.
 2. Inference UI (9872) also has version selector — set to v4.
 3. v4 outputs 48kHz (v2 was 32kHz). Best naturalness.

 ----- Workflow -----
 1. Drop training audio:  ${INSTALL_DIR}/raw/<speaker>/
 2. WebUI -> 0a. UVR5 (denoise, optional)
            -> 0b. Slice on silence
            -> 0c. ASR (faster-whisper large-v3)
            -> 0d. SubFix (correct transcripts)
 3. Train SoVITS v4 module (pick v4 model_version)
 4. Train GPT module
 5. Inference UI -> upload 5-10s reference + reference text + script

 ----- VRAM (16GB 6900XT) -----
 v4 inference: ~6-8GB.   v4 training: ~10-12GB.
 Stop ollama during training:
   sudo systemctl stop ollama
   sudo systemctl start ollama
============================================================
EOF
