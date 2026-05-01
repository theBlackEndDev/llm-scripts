#!/usr/bin/env bash
# One-shot: install GGUF text encoder for Wan + free RAM by removing fp8 encoder.
# Run on server. Idempotent.
#
#   sudo bash fix-wan-encoder-to-gguf.sh
#
# After this: re-run patch-workflows-mac.sh on Mac to swap workflow encoder loaders.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

readonly ENC_DIR="/opt/comfyui/models/text_encoders"
readonly NEW="umt5-xxl-encoder-Q4_K_M.gguf"

mkdir -p "${ENC_DIR}"
chown comfy:comfy "${ENC_DIR}"

if [[ -s "${ENC_DIR}/${NEW}" ]]; then
    echo "[+] Already have ${NEW}"
else
    echo "[+] Pulling ${NEW} (~3GB)"
    sudo -u comfy /opt/comfyui/.venv/bin/hf download \
        city96/umt5-xxl-encoder-gguf \
        "${NEW}" \
        --local-dir "${ENC_DIR}"
fi

# Drop the heavy fp8 file we no longer need.
HEAVY="${ENC_DIR}/umt5_xxl_fp8_e4m3fn_scaled.safetensors"
if [[ -f "${HEAVY}" ]]; then
    echo "[+] Removing heavy fp8 encoder (${HEAVY})"
    rm -f "${HEAVY}"
fi

# Drop the wasted fp16 5B model we accidentally pulled earlier.
FP16="/opt/comfyui/models/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors"
if [[ -f "${FP16}" ]]; then
    echo "[+] Removing oversized fp16 5B (${FP16})"
    rm -f "${FP16}"
fi

echo
echo "[+] Done. Files in ${ENC_DIR}:"
ls -lh "${ENC_DIR}"

cat <<EOF

Next steps on Mac:
  1. cd ~/Projects/llm-scripts && git pull
  2. bash patch-workflows-mac.sh   # swaps CLIPLoader -> CLIPLoaderGGUF
  3. Refresh ComfyUI tab, drag patched wan/video_wan2_2_5B_ti2v.json, Run.

Memory budget after this:
  Wan 5B Q4_K_M GGUF ........ ~3 GB
  umt5-xxl Q4_K_M GGUF ...... ~3 GB
  ComfyUI process ........... ~2 GB
  ----- total --------------- ~8 GB peak  (fits 16GB RAM with headroom)
EOF
