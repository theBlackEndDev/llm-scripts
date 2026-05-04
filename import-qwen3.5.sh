#!/usr/bin/env bash
# Import a local qwen3.5 GGUF into Ollama with proper ChatML template + stop tokens.
# Run on server (no sudo needed; uses your user's ollama daemon access).
#
#   bash import-qwen3.5.sh [path/to/qwen3.5-9b-Q4_K_M.gguf]
#
# If no path given, looks at default location.
# Idempotent. Re-run after upgrading the GGUF file.

set -euo pipefail

readonly DEFAULT_GGUF="${HOME}/models/qwen3.5-9b-Q4_K_M.gguf"
readonly TAG="qwen3.5:9b"

GGUF_PATH="${1:-${DEFAULT_GGUF}}"
[[ -f "${GGUF_PATH}" ]] || { echo "GGUF not found: ${GGUF_PATH}"; exit 1; }
command -v ollama >/dev/null || { echo "ollama missing"; exit 1; }

TMPL="$(mktemp)"
trap 'rm -f "${TMPL}"' EXIT

cat >"${TMPL}" <<EOF
FROM ${GGUF_PATH}

TEMPLATE """{{ if .System }}<|im_start|>system
{{ .System }}<|im_end|>
{{ end }}{{ if .Prompt }}<|im_start|>user
{{ .Prompt }}<|im_end|>
{{ end }}<|im_start|>assistant
{{ .Response }}<|im_end|>
"""

PARAMETER stop "<|im_start|>"
PARAMETER stop "<|im_end|>"
PARAMETER num_ctx 8192
PARAMETER num_predict 1024
EOF

if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "${TAG}"; then
    echo "[+] Removing old ${TAG}"
    ollama rm "${TAG}"
fi

echo "[+] Importing ${GGUF_PATH} as ${TAG}"
ollama create "${TAG}" -f "${TMPL}"

echo "[+] Smoke test"
ollama run "${TAG}" --verbose "say hi in one short sentence"
