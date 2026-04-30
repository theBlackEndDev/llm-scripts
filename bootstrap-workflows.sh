#!/usr/bin/env bash
# Fetch reference ComfyUI workflows from official/community sources
# and inject placeholders so /opt/videogen/03_render.py can drive them.
#
# Run on the server AFTER install-comfyui.sh + install-videogen-pipeline.sh.
# Run as `videogen` user: sudo -iu videogen ~/bootstrap-workflows.sh

set -euo pipefail

readonly WF_DIR="/opt/videogen/workflows"
readonly TMP_DIR="$(mktemp -d)"

log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

mkdir -p "${WF_DIR}"
cd "${TMP_DIR}"

inject() {
    local in="$1" out="$2"
    # Generic placeholder injection: relies on common Wan/LTX/Flux node patterns.
    # User can hand-tune in ComfyUI UI after.
    python3 - "$in" "$out" <<'PY'
import json, sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    raw = f.read()
data = json.loads(raw)

def walk(obj, parent=None, key=None):
    if isinstance(obj, dict):
        # heuristics: replace prompt-looking strings
        for k, v in list(obj.items()):
            if isinstance(v, str):
                kl = (k or "").lower()
                if "text" in kl or "prompt" in kl:
                    if v and not v.startswith("__"):
                        if "negative" in kl or "neg" in kl:
                            obj[k] = "__NEG_PROMPT__"
                        else:
                            obj[k] = "__PROMPT__"
                if kl == "filename_prefix":
                    obj[k] = "videogen_out"
            elif isinstance(v, (int, float)):
                if k == "seed":
                    obj[k] = "__SEED__"
                elif k in ("width",):
                    obj[k] = "__WIDTH__"
                elif k in ("height",):
                    obj[k] = "__HEIGHT__"
                elif k in ("length", "num_frames", "frames"):
                    obj[k] = "__FRAMES__"
                elif k in ("fps", "frame_rate"):
                    obj[k] = "__FPS__"
            walk(v, obj, k)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            walk(v, obj, i)

walk(data)
with open(dst, "w") as f:
    json.dump(data, f, indent=2)
print(f"[ok] {dst}")
PY
}

# ----- Wan 2.2 T2V -----
log "Wan 2.2 T2V workflow"
if curl -fsSL -o wan22_t2v.json \
    "https://raw.githubusercontent.com/comfyanonymous/ComfyUI_examples/master/wan22/wan2_2_text_to_video.json" 2>/dev/null; then
    inject wan22_t2v.json "${WF_DIR}/wan22_t2v.json"
else
    warn "Wan 2.2 T2V reference not found — leaving placeholder. Build manually in ComfyUI UI."
fi

# ----- Wan 2.2 I2V -----
log "Wan 2.2 I2V workflow"
if curl -fsSL -o wan22_i2v.json \
    "https://raw.githubusercontent.com/comfyanonymous/ComfyUI_examples/master/wan22/wan2_2_image_to_video.json" 2>/dev/null; then
    inject wan22_i2v.json "${WF_DIR}/wan22_i2v.json"
else
    warn "Wan 2.2 I2V reference not found"
fi

# ----- Wan 2.2 FLF2V (first+last frame) -----
log "Wan 2.2 FLF2V workflow"
if curl -fsSL -o wan22_flf2v.json \
    "https://raw.githubusercontent.com/kijai/ComfyUI-WanVideoWrapper/main/example_workflows/wanvideo_flf2v_example.json" 2>/dev/null; then
    inject wan22_flf2v.json "${WF_DIR}/wan22_flf2v.json"
else
    warn "Wan 2.2 FLF2V reference not found"
fi

# ----- LTX 2.3 T2V/I2V -----
log "LTX 2.3 workflows (if model installed)"
if [[ -f /opt/comfyui/models/diffusion_models/ltx-video-2.3-t2v-Q5_K_S.gguf ]]; then
    for kind in t2v i2v; do
        if curl -fsSL -o "ltx23_${kind}.json" \
            "https://raw.githubusercontent.com/Lightricks/ComfyUI-LTXVideo/main/example_workflows/ltx_${kind}_example.json" 2>/dev/null; then
            inject "ltx23_${kind}.json" "${WF_DIR}/ltx23_${kind}.json"
        else
            warn "LTX 2.3 ${kind} reference not found"
        fi
    done
else
    warn "LTX 2.3 model not present — skipping LTX workflows. Re-run with INSTALL_LTX=1 first."
fi

# ----- Flux Krea T2I -----
log "Flux Krea T2I workflow"
if curl -fsSL -o flux_krea_t2i.json \
    "https://raw.githubusercontent.com/comfyanonymous/ComfyUI_examples/master/flux/flux_dev_example.json" 2>/dev/null; then
    inject flux_krea_t2i.json "${WF_DIR}/flux_krea_t2i.json"
else
    warn "Flux Krea reference not found"
fi

# ----- SDXL T2I -----
log "SDXL T2I workflow"
if curl -fsSL -o sdxl_t2i.json \
    "https://raw.githubusercontent.com/comfyanonymous/ComfyUI_examples/master/sdxl/sdxl_simple_example.json" 2>/dev/null; then
    inject sdxl_t2i.json "${WF_DIR}/sdxl_t2i.json"
else
    warn "SDXL reference not found"
fi

# ----- validate via ComfyUI API -----
log "Validating workflows by querying ComfyUI /object_info (smoke test)"
if curl -fsS http://127.0.0.1:8188/object_info >/dev/null 2>&1; then
    for f in "${WF_DIR}"/*.json; do
        if jq -e '. | type == "object" and (.[][] // empty)' "$f" >/dev/null 2>&1; then
            echo "  ok-shape  $f"
        else
            warn "  shape-fail $f (likely placeholder, edit in ComfyUI UI)"
        fi
    done
else
    warn "ComfyUI not reachable on :8188 — start it first: sudo systemctl start comfyui"
fi

cd / && rm -rf "${TMP_DIR}"

cat <<EOF

============================================================
 Workflow bootstrap done.

 Installed JSONs in ${WF_DIR}:
$(ls -1 "${WF_DIR}"/*.json 2>/dev/null | sed 's/^/   /')

 Next step (one of):
   A) Open http://SERVER:8188 -> drag each JSON in -> Queue Prompt
      to verify it runs end-to-end. Save back via Workflow -> Save (API Format).

   B) Have Claude Code drive validation: queue test prompts via API,
      adjust missing/broken nodes, save corrected workflows.

 Placeholder fields injected: __PROMPT__, __NEG_PROMPT__, __SEED__,
                              __WIDTH__, __HEIGHT__, __FRAMES__, __FPS__
 If a workflow lacks a placeholder you need (e.g. __FIRST_FRAME__),
 open it in ComfyUI UI, find the relevant text/image-loader node,
 set its value to that exact string, then re-save (API Format).
============================================================
EOF
