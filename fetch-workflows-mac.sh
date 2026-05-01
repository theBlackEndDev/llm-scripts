#!/usr/bin/env bash
# Pull ONLY workflow JSONs that match what's installed on the llm server.
# Run on Mac. Drops curated set into ~/Projects/llm-scripts/workflows/.
#
#   bash fetch-workflows-mac.sh
#
# Stack on server:
#   - Wan 2.2 14B GGUF dual-expert (HighNoise + LowNoise) via QuantStack
#   - Wan 2.2 5B Turbo GGUF
#   - Comfy-Org Wan_2.2_ComfyUI_Repackaged (encoders / VAE / lightning LoRAs)
#   - FLUX.2 GGUF + Comfy-Org flux2-dev (encoders / VAE)
#   - Qwen-Image-2512 GGUF
#   - FLUX.1 Krea GGUF + flux ae
#   - SDXL base (safetensors)
#   - HunyuanVideo-Foley
#   - ACE-Step v1 3.5B
#   - IndexTTS-2
#   - MusicGen Stereo Large
#
# Anything kijai-WanVideoWrapper-style or that needs Ovi / MMAudio /
# FantasyTalking / InfiniteTalk / FantasyPortrait / MoCha / etc. is dropped.

set -euo pipefail

ROOT="${HOME}/Projects/llm-scripts/workflows"
TMP="$(mktemp -d)"

log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# Wipe stale folders that this script may have created previously.
rm -rf "${ROOT}/builtin" "${ROOT}/wan" "${ROOT}/gguf" \
       "${ROOT}/ace-step" "${ROOT}/indextts2" "${ROOT}/nag" \
       "${ROOT}/frame-interp" "${ROOT}/videohelper" "${ROOT}/foley" \
       "${ROOT}/civicomfy"

mkdir -p "${ROOT}"/{wan,flux,qwen-image,sdxl,ace-step,indextts2,foley,nag,videohelper}

# ---- 1. Comfy-Org built-in templates: filtered to compatible files ----
log "Built-in templates (Comfy-Org/workflow_templates)"
git clone --depth=1 https://github.com/Comfy-Org/workflow_templates "${TMP}/builtin" >/dev/null 2>&1

copy_match() {
    local src="$1" dst="$2"
    shift 2
    local pattern
    for pattern in "$@"; do
        find "${src}" -name "*.json" -iname "${pattern}" -exec cp {} "${dst}/" \; 2>/dev/null || true
    done
}

# Wan 2.2 (matches our Comfy-Org repackage + GGUF stack)
copy_match "${TMP}/builtin" "${ROOT}/wan" \
    "*wan2_2_5B*.json" \
    "*wan2_2_14B_t2v*.json" \
    "*wan2_2_14B_i2v*.json" \
    "*wan2_2_14B_flf2v*.json" \
    "text_to_video_wan_2_2.json" \
    "image_to_video_wan_2_2.json" \
    "api_wan_text_to_video.json" \
    "api_wan_image_to_video.json"

# FLUX (we have flux2-dev + flux1-krea-dev)
copy_match "${TMP}/builtin" "${ROOT}/flux" \
    "*flux*dev*.json" \
    "*flux*krea*.json" \
    "*flux2*.json" \
    "image_flux*.json"

# Qwen-Image
copy_match "${TMP}/builtin" "${ROOT}/qwen-image" \
    "*qwen*image*.json" \
    "*qwen_image*.json"

# SDXL basic
copy_match "${TMP}/builtin" "${ROOT}/sdxl" \
    "*sdxl_base*.json" \
    "*sdxl_simple*.json" \
    "image_generation*.json"

# ---- 2. ACE-Step (we use billwuhao node) ----
log "ACE-Step (billwuhao/ComfyUI_ACE-Step)"
git clone --depth=1 https://github.com/billwuhao/ComfyUI_ACE-Step "${TMP}/ace" >/dev/null 2>&1 || true
find "${TMP}/ace" -name "*.json" -exec cp {} "${ROOT}/ace-step/" \; 2>/dev/null || true

# ---- 3. IndexTTS-2 (snicolast node) ----
log "IndexTTS-2 (snicolast/ComfyUI-IndexTTS2)"
git clone --depth=1 https://github.com/snicolast/ComfyUI-IndexTTS2 "${TMP}/indextts" >/dev/null 2>&1 || true
find "${TMP}/indextts" -name "*.json" -exec cp {} "${ROOT}/indextts2/" \; 2>/dev/null || true

# ---- 4. Hunyuan-Foley (aistudynow node) ----
log "Hunyuan-Foley (aistudynow/Comfyui-HunyuanFoley)"
git clone --depth=1 https://github.com/aistudynow/Comfyui-HunyuanFoley "${TMP}/foley" >/dev/null 2>&1 || true
find "${TMP}/foley" -name "*.json" -exec cp {} "${ROOT}/foley/" \; 2>/dev/null || true

# ---- 5. NAG (low-CFG negative-prompt boost — used with Wan 5B Turbo) ----
log "NAG (ChenDarYen/ComfyUI-NAG)"
git clone --depth=1 https://github.com/ChenDarYen/ComfyUI-NAG "${TMP}/nag" >/dev/null 2>&1 || true
find "${TMP}/nag" -name "*.json" -exec cp {} "${ROOT}/nag/" \; 2>/dev/null || true

# ---- 6. VideoHelperSuite (utility, used as combine/save in any video workflow) ----
log "VideoHelperSuite (Kosinkadink/ComfyUI-VideoHelperSuite)"
git clone --depth=1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite "${TMP}/vhs" >/dev/null 2>&1 || true
find "${TMP}/vhs" -name "*.json" -exec cp {} "${ROOT}/videohelper/" \; 2>/dev/null || true

# ---- cleanup ----
rm -rf "${TMP}"

# ---- prune empty subfolders ----
for d in "${ROOT}"/*/; do
    [[ -z "$(ls -A "$d" 2>/dev/null)" ]] && rmdir "$d"
done

# ---- summary ----
echo
log "Curated set:"
for d in "${ROOT}"/*/; do
    [[ -d "$d" ]] || continue
    n=$(find "$d" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    printf "  %-15s %s JSONs\n" "$(basename "$d")" "$n"
done

cat <<EOF

Drag-and-drop from Finder into ComfyUI canvas.

Recommended order:
  sdxl/                 — sanity check, you've already done this
  flux/                 — try flux2 + flux1-krea (image quality)
  qwen-image/           — strong text rendering
  wan/                  — try video_wan2_2_5B_ti2v.json FIRST (cheapest)
  ace-step/             — music
  indextts2/            — zero-shot voice
  foley/                — ambient/SFX over silent clips
EOF
