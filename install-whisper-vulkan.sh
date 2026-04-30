#!/usr/bin/env bash
# whisper.cpp Vulkan server — Ubuntu Server 24.04 + AMD 6900XT
# Exposes:
#   POST http://HOST:9000/inference                       (native whisper.cpp)
#   POST http://HOST:9000/v1/audio/transcriptions         (OpenAI-compat shim via nginx)
# Compatible with OpenWhispr "Custom Whisper Server" mode.

set -euo pipefail

readonly INSTALL_DIR="/opt/whisper.cpp"
readonly MODEL="large-v3-turbo"
readonly SERVICE_USER="whisper"
readonly WHISPER_PORT=9001       # internal (nginx upstream)
readonly PUBLIC_PORT=9000        # external (OpenAI-compat + native passthrough)
readonly LAN_CIDR="192.168.0.0/16"

log() { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run with sudo."

log "Installing build deps + Vulkan + nginx"
apt-get update
apt-get install -y --no-install-recommends \
    build-essential cmake git curl jq ca-certificates pkg-config \
    libvulkan-dev mesa-vulkan-drivers vulkan-tools \
    libcurl4-openssl-dev nginx ufw ffmpeg

log "Verifying Vulkan sees the GPU"
if ! vulkaninfo --summary 2>/dev/null | grep -Eqi 'radeon|amd|6900'; then
    vulkaninfo --summary || true
    err "GPU not visible to Vulkan. Confirm 'amdgpu' kernel module + mesa-vulkan-drivers."
fi

log "Creating service user '${SERVICE_USER}'"
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd -r -m -d /var/lib/${SERVICE_USER} -s /usr/sbin/nologin "${SERVICE_USER}"
fi
usermod -aG video,render "${SERVICE_USER}"

log "Cloning whisper.cpp into ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    git clone --depth=1 https://github.com/ggml-org/whisper.cpp.git "${INSTALL_DIR}"
else
    git -C "${INSTALL_DIR}" pull --ff-only
fi

log "Building (Vulkan + server)"
cmake -S "${INSTALL_DIR}" -B "${INSTALL_DIR}/build" \
    -DGGML_VULKAN=1 \
    -DWHISPER_BUILD_SERVER=1 \
    -DCMAKE_BUILD_TYPE=Release
cmake --build "${INSTALL_DIR}/build" -j"$(nproc)"

log "Downloading model: ${MODEL}"
sudo -u "${SERVICE_USER}" -H bash -c "cd '${INSTALL_DIR}' && bash models/download-ggml-model.sh '${MODEL}'" \
  || (cd "${INSTALL_DIR}" && bash models/download-ggml-model.sh "${MODEL}")

chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"

log "Writing systemd unit"
cat >/etc/systemd/system/whisper.service <<EOF
[Unit]
Description=whisper.cpp Vulkan server (6900XT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
SupplementaryGroups=video render
WorkingDirectory=${INSTALL_DIR}
Environment=GGML_VK_VISIBLE_DEVICES=0
ExecStart=${INSTALL_DIR}/build/bin/whisper-server \\
    -m ${INSTALL_DIR}/models/ggml-${MODEL}.bin \\
    --host 127.0.0.1 \\
    --port ${WHISPER_PORT} \\
    -t $(nproc) \\
    --convert
Restart=always
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

log "Writing nginx OpenAI-compat shim on port ${PUBLIC_PORT}"
cat >/etc/nginx/sites-available/whisper <<EOF
server {
    listen ${PUBLIC_PORT};
    listen [::]:${PUBLIC_PORT};
    server_name _;

    client_max_body_size 200M;
    proxy_read_timeout  300s;
    proxy_send_timeout  300s;

    # OpenAI-compatible paths -> whisper.cpp /inference
    location = /v1/audio/transcriptions {
        proxy_pass http://127.0.0.1:${WHISPER_PORT}/inference;
        proxy_set_header Host \$host;
    }
    location = /v1/audio/translations {
        proxy_pass http://127.0.0.1:${WHISPER_PORT}/inference;
        proxy_set_header Host \$host;
    }
    # OpenWhispr-style (no /v1 prefix)
    location = /audio/transcriptions {
        proxy_pass http://127.0.0.1:${WHISPER_PORT}/inference;
        proxy_set_header Host \$host;
    }
    location = /audio/translations {
        proxy_pass http://127.0.0.1:${WHISPER_PORT}/inference;
        proxy_set_header Host \$host;
    }

    # Native whisper.cpp endpoints (OpenWhispr custom-server mode)
    location / {
        proxy_pass http://127.0.0.1:${WHISPER_PORT};
        proxy_set_header Host \$host;
    }
}
EOF
ln -sf /etc/nginx/sites-available/whisper /etc/nginx/sites-enabled/whisper
rm -f /etc/nginx/sites-enabled/default
nginx -t

log "Enabling services"
systemctl daemon-reload
systemctl enable --now whisper
systemctl reload nginx || systemctl restart nginx

log "Configuring UFW (LAN only)"
if command -v ufw >/dev/null 2>&1; then
    ufw allow from "${LAN_CIDR}" to any port "${PUBLIC_PORT}" proto tcp comment 'whisper LAN' || true
fi

log "Waiting for server to come up"
for i in {1..20}; do
    if curl -fsS "http://127.0.0.1:${WHISPER_PORT}/" >/dev/null 2>&1 \
       || curl -fsS -X POST "http://127.0.0.1:${WHISPER_PORT}/inference" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

log "Smoke test"
if [[ -f "${INSTALL_DIR}/samples/jfk.wav" ]]; then
    curl -fsS -X POST "http://127.0.0.1:${PUBLIC_PORT}/inference" \
        -F "file=@${INSTALL_DIR}/samples/jfk.wav" \
        -F "response_format=json" | jq . || true
    echo
    curl -fsS -X POST "http://127.0.0.1:${PUBLIC_PORT}/v1/audio/transcriptions" \
        -F "file=@${INSTALL_DIR}/samples/jfk.wav" \
        -F "model=whisper-1" \
        -F "response_format=json" | jq . || true
fi

IP=$(hostname -I | awk '{print $1}')
cat <<EOF

============================================================
 whisper.cpp Vulkan server up.

 Service:  systemctl status whisper
 Logs:     journalctl -u whisper -f
 Endpoints (LAN):
   Native:    http://${IP}:${PUBLIC_PORT}/inference
   OpenAI:    http://${IP}:${PUBLIC_PORT}/v1/audio/transcriptions

 OpenWhispr setup:
   Settings -> Custom Whisper Server
     URL:   http://${IP}:${PUBLIC_PORT}
     Model: ${MODEL}
   (Or OpenAI-compatible mode -> base URL: http://${IP}:${PUBLIC_PORT}/v1)

 Model: ${INSTALL_DIR}/models/ggml-${MODEL}.bin
 Swap models: edit /etc/systemd/system/whisper.service then
              sudo systemctl daemon-reload && sudo systemctl restart whisper
============================================================
EOF
