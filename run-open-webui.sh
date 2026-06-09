#!/usr/bin/env bash
# Run (or re-create) the Open WebUI container, wired to BOTH local backends:
#   - llama-server (OpenAI-compatible) on :8081  -> shows the active profile's model
#   - Ollama on :11434                            -> shows ollama models when running
#
# Idempotent: stops/removes any existing container and recreates it. The user
# data (accounts, chats, settings) lives in the named volume `open-webui` and is
# preserved across recreates.
#
# Run: ./run-open-webui.sh          (no sudo needed if your user is in docker group)

set -euo pipefail

readonly NAME="open-webui"
readonly IMAGE="ghcr.io/open-webui/open-webui:main"
readonly VOLUME="open-webui"           # named volume -> /app/backend/data
readonly HOST_PORT="${HOST_PORT:-3000}"  # browser: http://<box>:3000
readonly LLAMA_PORT="${LLAMA_PORT:-8081}"
readonly OLLAMA_PORT="${OLLAMA_PORT:-11434}"

log() { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }

command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 1; }

log "Pulling latest ${IMAGE}"
docker pull "${IMAGE}" >/dev/null

if docker ps -a --format '{{.Names}}' | grep -qx "${NAME}"; then
    log "Removing existing ${NAME} container (data volume kept)"
    docker rm -f "${NAME}" >/dev/null
fi

log "Starting ${NAME} on :${HOST_PORT} (llama-server :${LLAMA_PORT} + ollama :${OLLAMA_PORT})"
# host.docker.internal:host-gateway lets the container reach services on the host.
docker run -d \
    --name "${NAME}" \
    -p "${HOST_PORT}:8080" \
    --add-host host.docker.internal:host-gateway \
    -v "${VOLUME}:/app/backend/data" \
    -e OPENAI_API_BASE_URL="http://host.docker.internal:${LLAMA_PORT}/v1" \
    -e OPENAI_API_KEY=not-needed \
    -e ENABLE_OLLAMA_API=true \
    -e OLLAMA_BASE_URL="http://host.docker.internal:${OLLAMA_PORT}" \
    --restart unless-stopped \
    "${IMAGE}" >/dev/null

log "Waiting for healthy"
for _ in $(seq 1 24); do
    [[ "$(docker inspect "${NAME}" --format '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]] && break
    sleep 5
done

state=$(docker inspect "${NAME}" --format '{{.State.Health.Status}}' 2>/dev/null || echo unknown)
log "Open WebUI is ${state} -> http://localhost:${HOST_PORT}"
echo
echo "Backends:"
echo "  OpenAI (llama-server): http://host.docker.internal:${LLAMA_PORT}/v1"
echo "  Ollama:                http://host.docker.internal:${OLLAMA_PORT}"
echo "Model list reflects the active 'profile' (llama-server) + ollama when running."
