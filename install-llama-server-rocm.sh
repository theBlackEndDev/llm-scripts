#!/usr/bin/env bash
# Build llama.cpp with ROCm/HIP + flash attention, install as systemd llama-server.
# Auto-picks an appropriate MoE model based on available system RAM.
#
# Run: sudo ./install-llama-server-rocm.sh
#
# Tiered model picks (auto-detect via /proc/meminfo):
#   16GB RAM  -> gpt-oss-20b   (MXFP4, ~12-13GB, runs nearly fully on 6900XT)
#   32GB RAM  -> qwen3-coder-30b-a3b Q4_K_M  + mistral devstral
#   64GB RAM  -> qwen3.5-35b-a3b Q4_K_M  + glm-4.7  + devstral
#
# Why llama-server (not Ollama):
#   - Ollama lacks --n-cpu-moe / --override-tensor for MoE expert offload
#   - llama.cpp gets new model arch support faster
#   - Lets us pull custom GGUFs (Codacus-style optimization)
#
# Coexists with Ollama. Different port (8081 vs 11434). Open WebUI sees both.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

readonly INSTALL_DIR="/opt/llama-cpp"
readonly MODEL_DIR="/opt/llama-cpp/models"
readonly SERVICE_USER="llama"
readonly PORT=8081
readonly LAN_CIDR="192.168.0.0/16"

log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- detect ROCm ----
ROCM_VER=""
[[ -f /opt/rocm/.info/version ]] && ROCM_VER=$(< /opt/rocm/.info/version)
[[ -n "$ROCM_VER" ]] || err "ROCm not detected. Need /opt/rocm/.info/version."
log "ROCm $ROCM_VER detected"

# ---- detect RAM tier ----
RAM_GB=$(free -g | awk '/^Mem:/ {print $2}')
log "System RAM: ${RAM_GB}GB"

if   (( RAM_GB >= 60 )); then TIER="64gb"
elif (( RAM_GB >= 28 )); then TIER="32gb"
else                          TIER="16gb"
fi
log "Tier: ${TIER}"

# ---- system deps ----
log "System deps"
apt-get update
apt-get install -y --no-install-recommends \
    build-essential cmake git curl ca-certificates \
    python3 python3-venv python3-pip \
    libcurl4-openssl-dev pkg-config

# ---- service user ----
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    log "Creating ${SERVICE_USER} user"
    useradd -r -m -d /var/lib/${SERVICE_USER} -s /bin/bash "${SERVICE_USER}"
fi
usermod -aG video,render "${SERVICE_USER}"

# ---- clone + build llama.cpp ----
mkdir -p "${INSTALL_DIR}" "${MODEL_DIR}"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"

if [[ ! -d "${INSTALL_DIR}/src/.git" ]]; then
    log "Cloning llama.cpp"
    sudo -u "${SERVICE_USER}" git clone --depth=1 https://github.com/ggml-org/llama.cpp "${INSTALL_DIR}/src"
else
    log "Updating llama.cpp"
    sudo -u "${SERVICE_USER}" git -C "${INSTALL_DIR}/src" pull --ff-only || warn "git pull failed (non-fatal)"
fi

log "Building llama.cpp with HIP + flash attention (this takes a while)"
sudo -u "${SERVICE_USER}" bash <<EOF
set -euo pipefail
export PATH="/opt/rocm/bin:/opt/rocm/llvm/bin:\${PATH}"
cd ${INSTALL_DIR}/src
rm -rf build
cmake -B build -G Ninja \\
    -DGGML_HIP=ON \\
    -DAMDGPU_TARGETS=gfx1030 \\
    -DCMAKE_BUILD_TYPE=Release \\
    -DLLAMA_CURL=ON \\
    -DGGML_HIP_GRAPHS=ON 2>/dev/null || \\
cmake -B build \\
    -DGGML_HIP=ON \\
    -DAMDGPU_TARGETS=gfx1030 \\
    -DCMAKE_BUILD_TYPE=Release \\
    -DLLAMA_CURL=ON
cmake --build build --config Release -j\$(nproc)
EOF

# ---- python venv for hf download ----
if [[ ! -d "${INSTALL_DIR}/.venv" ]]; then
    sudo -u "${SERVICE_USER}" python3 -m venv "${INSTALL_DIR}/.venv"
fi
sudo -u "${SERVICE_USER}" "${INSTALL_DIR}/.venv/bin/pip" install --upgrade pip huggingface_hub hf_transfer

# ---- helper: hf download wrapper ----
hf_pull() {
    local repo="$1" file="$2"
    local dest="${MODEL_DIR}/$(basename "${file}")"
    if [[ -s "${dest}" ]]; then
        log "Already have $(basename "${file}")"
        return
    fi
    log "Pulling ${repo} :: ${file}"
    sudo -u "${SERVICE_USER}" \
        HF_HUB_ENABLE_HF_TRANSFER=1 \
        "${INSTALL_DIR}/.venv/bin/hf" download "${repo}" "${file}" --local-dir "${MODEL_DIR}"
    # Move into flat MODEL_DIR if HF nested it
    found=$(find "${MODEL_DIR}" -maxdepth 6 -name "$(basename "${file}")" -type f | head -1)
    if [[ "${found}" != "${dest}" && -n "${found}" ]]; then
        mv "${found}" "${dest}"
    fi
    chown "${SERVICE_USER}:${SERVICE_USER}" "${dest}"
}

# ---- pull tier-appropriate models ----
case "${TIER}" in
    16gb)
        log "Pulling gpt-oss-20b (MXFP4, fits 16GB RAM)"
        hf_pull "ggml-org/gpt-oss-20b-GGUF" "gpt-oss-20b-mxfp4.gguf"
        DEFAULT_MODEL="gpt-oss-20b-mxfp4.gguf"
        DEFAULT_NCPUMOE=0     # fits VRAM, no offload needed
        DEFAULT_CTX=32768
        ;;
    32gb)
        log "Pulling qwen3-coder-30b-a3b Q4_K_M"
        hf_pull "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF" "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
        log "Pulling Mistral Devstral 256K context"
        hf_pull "unsloth/Devstral-Small-2505-GGUF" "Devstral-Small-2505-Q4_K_M.gguf" || warn "devstral pull failed (non-fatal)"
        DEFAULT_MODEL="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
        DEFAULT_NCPUMOE=20    # offload most experts to CPU
        DEFAULT_CTX=32768
        ;;
    64gb)
        log "Pulling qwen3.5-35b-a3b Q4_K_M"
        hf_pull "unsloth/Qwen3.5-35B-A3B-Instruct-GGUF" "Qwen3.5-35B-A3B-Instruct-Q4_K_M.gguf" || \
            hf_pull "bartowski/Qwen_Qwen3-30B-A3B-GGUF" "Qwen_Qwen3-30B-A3B-Q4_K_M.gguf"
        log "Pulling GLM-4.7 (SWE-bench leader)"
        hf_pull "bartowski/THUDM_GLM-4-32B-0414-GGUF" "THUDM_GLM-4-32B-0414-Q4_K_M.gguf" || warn "glm pull failed (non-fatal)"
        log "Pulling Mistral Devstral 256K context"
        hf_pull "unsloth/Devstral-Small-2505-GGUF" "Devstral-Small-2505-Q4_K_M.gguf" || warn "devstral pull failed (non-fatal)"
        DEFAULT_MODEL="Qwen3.5-35B-A3B-Instruct-Q4_K_M.gguf"
        DEFAULT_NCPUMOE=24
        DEFAULT_CTX=65536
        ;;
esac

# ---- systemd unit ----
log "Writing systemd unit"
cat >/etc/systemd/system/llama-server.service <<EOF
[Unit]
Description=llama.cpp llama-server (MoE-tuned for AMD ROCm)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
SupplementaryGroups=video render
WorkingDirectory=${INSTALL_DIR}
Environment=HSA_OVERRIDE_GFX_VERSION=10.3.0
Environment=PYTORCH_HIP_ALLOC_CONF=expandable_segments:True
Environment=LLAMA_MODEL=${DEFAULT_MODEL}
Environment=LLAMA_NCPUMOE=${DEFAULT_NCPUMOE}
Environment=LLAMA_CTX=${DEFAULT_CTX}
ExecStart=/bin/bash -c '${INSTALL_DIR}/src/build/bin/llama-server \\
    --model ${MODEL_DIR}/\${LLAMA_MODEL} \\
    --host 0.0.0.0 \\
    --port ${PORT} \\
    --n-gpu-layers 999 \\
    --n-cpu-moe \${LLAMA_NCPUMOE} \\
    --flash-attn on \\
    --cache-type-k q8_0 \\
    --cache-type-v q8_0 \\
    --ctx-size \${LLAMA_CTX} \\
    --batch-size 2048 \\
    --ubatch-size 512 \\
    --threads \$(nproc) \\
    --no-mmap \\
    --metrics'
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# ---- UFW (LAN only) ----
if command -v ufw >/dev/null 2>&1; then
    ufw allow from "${LAN_CIDR}" to any port ${PORT} proto tcp comment "llama-server" || true
fi

# ---- enable + start ----
systemctl daemon-reload
systemctl enable --now llama-server

sleep 8
log "Smoke test"
if curl -fsS "http://127.0.0.1:${PORT}/health" | grep -q ok; then
    log "llama-server responding on :${PORT}"
else
    warn "llama-server not responding yet; check 'journalctl -u llama-server -f'"
fi

IP=$(hostname -I | awk '{print $1}')
cat <<EOF

============================================================
 llama-server (MoE-tuned) up.

 Tier:      ${TIER}
 Default:   ${DEFAULT_MODEL}
 Endpoint:  http://${IP}:${PORT}/v1/chat/completions  (OpenAI-compatible)
 Health:    http://${IP}:${PORT}/health
 Models:    ls ${MODEL_DIR}

 Logs:      sudo journalctl -u llama-server -f

 Switch model (no rebuild):
   sudo systemctl edit llama-server
   # change Environment=LLAMA_MODEL=...
   sudo systemctl restart llama-server

 Tune --n-cpu-moe:
   higher = more experts to CPU = less VRAM, slower
   lower  = more experts on GPU = more VRAM, faster
   (start at default, lower until OOM, back off one)

 Coexists with Ollama (port 11434). Open WebUI sees both:
   Settings -> Connections -> add http://localhost:${PORT}
============================================================
EOF
