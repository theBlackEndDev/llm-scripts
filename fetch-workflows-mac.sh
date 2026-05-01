#!/usr/bin/env bash
# Pull every reference workflow JSON onto the Mac so you can drag-drop into
# ComfyUI in the browser. Run on Mac, not the server.
#
#   bash fetch-workflows-mac.sh
#
# Drops files into ~/Projects/llm-scripts/workflows/<source>/

set -euo pipefail

ROOT="${HOME}/Projects/llm-scripts/workflows"
TMP="$(mktemp -d)"

log() { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }

mkdir -p "${ROOT}"/{builtin,wan,gguf,ace-step,indextts2,nag,frame-interp,videohelper,foley,civicomfy}

# ---- Comfy-Org built-in templates ----
log "Built-in templates (Comfy-Org/workflow_templates)"
git clone --depth=1 https://github.com/Comfy-Org/workflow_templates "${TMP}/builtin" >/dev/null 2>&1
find "${TMP}/builtin" -name "*.json" -exec cp {} "${ROOT}/builtin/" \;

# ---- ComfyUI-GGUF example workflows ----
log "GGUF examples (city96/ComfyUI-GGUF)"
git clone --depth=1 https://github.com/city96/ComfyUI-GGUF "${TMP}/gguf" >/dev/null 2>&1
find "${TMP}/gguf" -name "*.json" -path "*example*" -exec cp {} "${ROOT}/gguf/" \; 2>/dev/null || true

# ---- Wan video wrapper examples ----
log "Wan workflows (kijai/ComfyUI-WanVideoWrapper)"
git clone --depth=1 https://github.com/kijai/ComfyUI-WanVideoWrapper "${TMP}/wan" >/dev/null 2>&1
find "${TMP}/wan" -name "*.json" -exec cp {} "${ROOT}/wan/" \; 2>/dev/null || true

# ---- ACE-Step examples ----
log "ACE-Step (billwuhao/ComfyUI_ACE-Step)"
git clone --depth=1 https://github.com/billwuhao/ComfyUI_ACE-Step "${TMP}/ace" >/dev/null 2>&1 || true
find "${TMP}/ace" -name "*.json" -exec cp {} "${ROOT}/ace-step/" \; 2>/dev/null || true

# ---- IndexTTS-2 examples ----
log "IndexTTS-2 (snicolast/ComfyUI-IndexTTS2)"
git clone --depth=1 https://github.com/snicolast/ComfyUI-IndexTTS2 "${TMP}/indextts" >/dev/null 2>&1 || true
find "${TMP}/indextts" -name "*.json" -exec cp {} "${ROOT}/indextts2/" \; 2>/dev/null || true

# ---- NAG node examples (low-CFG negative prompt energy boost) ----
log "NAG (ChenDarYen/ComfyUI-NAG)"
git clone --depth=1 https://github.com/ChenDarYen/ComfyUI-NAG "${TMP}/nag" >/dev/null 2>&1 || true
find "${TMP}/nag" -name "*.json" -exec cp {} "${ROOT}/nag/" \; 2>/dev/null || true

# ---- Frame Interpolation examples ----
log "Frame Interpolation (Fannovel16/ComfyUI-Frame-Interpolation)"
git clone --depth=1 https://github.com/Fannovel16/ComfyUI-Frame-Interpolation "${TMP}/frame-interp" >/dev/null 2>&1 || true
find "${TMP}/frame-interp" -name "*.json" -exec cp {} "${ROOT}/frame-interp/" \; 2>/dev/null || true

# ---- VideoHelperSuite examples ----
log "VideoHelperSuite (Kosinkadink/ComfyUI-VideoHelperSuite)"
git clone --depth=1 https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite "${TMP}/vhs" >/dev/null 2>&1 || true
find "${TMP}/vhs" -name "*.json" -exec cp {} "${ROOT}/videohelper/" \; 2>/dev/null || true

# ---- HunyuanVideo-Foley examples ----
log "Hunyuan-Foley (aistudynow/Comfyui-HunyuanFoley)"
git clone --depth=1 https://github.com/aistudynow/Comfyui-HunyuanFoley "${TMP}/foley" >/dev/null 2>&1 || true
find "${TMP}/foley" -name "*.json" -exec cp {} "${ROOT}/foley/" \; 2>/dev/null || true

# ---- Civicomfy (Civitai integration) examples ----
log "Civicomfy (MoonGoblinDev/Civicomfy)"
git clone --depth=1 https://github.com/MoonGoblinDev/Civicomfy "${TMP}/civi" >/dev/null 2>&1 || true
find "${TMP}/civi" -name "*.json" -exec cp {} "${ROOT}/civicomfy/" \; 2>/dev/null || true

# ---- cleanup ----
rm -rf "${TMP}"

# ---- summary ----
echo
log "Done. Counts per source:"
for d in "${ROOT}"/*/; do
    n=$(find "$d" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    printf "  %-20s %s\n" "$(basename "$d")" "${n} JSONs"
done

cat <<EOF

Workflows at: ${ROOT}

Drag-and-drop:
  Open ${ROOT} in Finder, drag any .json into ComfyUI canvas in browser.

Recommended starts:
  builtin/                 — official Comfy-Org templates (most stable)
  gguf/                    — confirms GGUF loaders work
  wan/                     — Wan 2.2 video, look for *5B* + *I2V* + *T2V*
EOF
