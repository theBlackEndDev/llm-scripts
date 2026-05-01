#!/usr/bin/env bash
# Patch fetched workflows to match our actual installed GGUF stack and
# 16GB VRAM / 16GB RAM budget. Idempotent — re-run anytime.
#
#   bash patch-workflows-mac.sh
#
# Reads ~/Projects/llm-scripts/workflows/<topic>/*.json
# Writes ~/Projects/llm-scripts/workflows-patched/<topic>/*.json

set -euo pipefail

SRC="${HOME}/Projects/llm-scripts/workflows"
DST="${HOME}/Projects/llm-scripts/workflows-patched"

[[ -d "${SRC}" ]] || { echo "Run fetch-workflows-mac.sh first."; exit 1; }

rm -rf "${DST}"
mkdir -p "${DST}"

python3 <<'PY'
import json, os, re, shutil
from pathlib import Path

SRC = Path.home() / "Projects/llm-scripts/workflows"
DST = Path.home() / "Projects/llm-scripts/workflows-patched"

# ---- target stack (matches /opt/comfyui/models on server) ----
WAN_5B_GGUF      = "Wan2.2-TI2V-5B-Q4_K_M.gguf"
WAN_14B_T2V_HI   = "HighNoise/Wan2.2-T2V-A14B-HighNoise-Q4_K_M.gguf"
WAN_14B_T2V_LO   = "LowNoise/Wan2.2-T2V-A14B-LowNoise-Q4_K_M.gguf"
WAN_14B_I2V_HI   = "HighNoise/Wan2.2-I2V-A14B-HighNoise-Q4_K_M.gguf"
WAN_14B_I2V_LO   = "LowNoise/Wan2.2-I2V-A14B-LowNoise-Q4_K_M.gguf"
FLUX2_GGUF       = "flux2-dev-Q5_K_M.gguf"
FLUX_KREA_GGUF   = "flux1-krea-dev-Q8_0.gguf"
QWEN_IMG_GGUF    = "qwen-image-2512-Q4_K_M.gguf"

# ---- VRAM-safe defaults for 16GB RDNA2 (no Flash Attention) ----
WAN_5B_W, WAN_5B_H, WAN_5B_LEN     = 832, 480, 33
WAN_14B_W, WAN_14B_H, WAN_14B_LEN  = 480, 272, 33
IMG_W, IMG_H                        = 1024, 1024

def fname_for(path: str) -> str:
    """Pick GGUF filename based on workflow path / contents."""
    p = path.lower()
    if "wan2_2_5b" in p or "5b_ti2v" in p or "tiv_5b" in p:
        return WAN_5B_GGUF
    if "wan2_2_14b_t2v" in p:
        return None  # dual-expert handled separately
    if "wan2_2_14b_i2v" in p or "wan2_2_14b_flf2v" in p:
        return None
    if "flux2" in p:
        return FLUX2_GGUF
    if "flux1_krea" in p or "flux_krea" in p:
        return FLUX_KREA_GGUF
    if "qwen" in p:
        return QWEN_IMG_GGUF
    return None

def is_dual_expert(path: str) -> str:
    p = path.lower()
    if "wan2_2_14b_t2v" in p: return "t2v"
    if "wan2_2_14b_i2v" in p or "wan2_2_14b_flf2v" in p: return "i2v"
    return ""

def patch_unet_loader(node, gguf_name):
    """Convert UNETLoader -> UnetLoaderGGUF with GGUF filename."""
    if node.get("type") != "UNETLoader" and node.get("class_type") != "UNETLoader":
        return False
    if "type" in node:
        node["type"] = "UnetLoaderGGUF"
    if "class_type" in node:
        node["class_type"] = "UnetLoaderGGUF"
    # widgets: first is filename; drop weight_dtype
    if isinstance(node.get("widgets_values"), list) and node["widgets_values"]:
        node["widgets_values"] = [gguf_name]
    if "inputs" in node and isinstance(node["inputs"], dict) and "unet_name" in node["inputs"]:
        node["inputs"]["unet_name"] = gguf_name
        node["inputs"].pop("weight_dtype", None)
    node.setdefault("properties", {})["Node name for S&R"] = "UnetLoaderGGUF"
    return True

def patch_latent_dims(nodes, w, h, length):
    """Lower Wan latent / EmptyLatentImage / EmptySDXLLatent dims to fit VRAM."""
    targets = (
        "Wan22ImageToVideoLatent",
        "EmptyHunyuanLatentVideo",
        "EmptyLatentImage",
        "EmptySD3LatentImage",
        "WanImageToVideo",
    )
    for n in nodes:
        t = n.get("type") or n.get("class_type")
        if t not in targets:
            continue
        wv = n.get("widgets_values")
        if isinstance(wv, list):
            # Common ordering: [width, height, length, batch_size]
            for i, v in enumerate(wv):
                if not isinstance(v, (int, float)): continue
                if i == 0 and v > w:        wv[i] = w
                elif i == 1 and v > h:      wv[i] = h
                elif i == 2 and length and v > length: wv[i] = length
        if isinstance(n.get("inputs"), dict):
            for k in ("width","height"):
                if k in n["inputs"] and isinstance(n["inputs"][k],(int,float)):
                    n["inputs"][k] = w if k=="width" else h
            if length and "length" in n["inputs"]:
                n["inputs"]["length"] = length

def patch_vae_decode_tiled(nodes, is_video: bool):
    """Swap VAEDecode -> VAEDecodeTiled with tile params.
    For video: tile_size=128, overlap=32, temporal_size=32, temporal_overlap=4
    For images: tile_size=512, overlap=64
    """
    for n in nodes:
        t = n.get("type") or n.get("class_type")
        if t != "VAEDecode":
            continue
        if "type" in n: n["type"] = "VAEDecodeTiled"
        if "class_type" in n: n["class_type"] = "VAEDecodeTiled"
        n.setdefault("properties", {})["Node name for S&R"] = "VAEDecodeTiled"
        if is_video:
            n["widgets_values"] = [128, 32, 32, 4]   # tile, overlap, temporal_size, temporal_overlap
            if isinstance(n.get("inputs"), dict):
                n["inputs"]["tile_size"] = 128
                n["inputs"]["overlap"] = 32
                n["inputs"]["temporal_size"] = 32
                n["inputs"]["temporal_overlap"] = 4
        else:
            n["widgets_values"] = [512, 64]
            if isinstance(n.get("inputs"), dict):
                n["inputs"]["tile_size"] = 512
                n["inputs"]["overlap"] = 64

def patch_workflow(src: Path, dst: Path):
    with open(src) as f:
        try:
            w = json.load(f)
        except json.JSONDecodeError:
            return False

    # Two formats: "graph" (with .nodes list) and "API" (dict of node-id -> node)
    nodes = []
    if isinstance(w, dict) and isinstance(w.get("nodes"), list):
        nodes = w["nodes"]                           # graph format
    elif isinstance(w, dict):
        nodes = list(w.values()) if all(
            isinstance(v, dict) and "class_type" in v for v in w.values()
        ) else []

    if not nodes:
        return False

    name = src.name
    ggu = fname_for(name)
    dual = is_dual_expert(name)

    is_video = ("wan" in name.lower() or "video" in name.lower() or
                "i2v" in name.lower() or "t2v" in name.lower() or
                "ltx" in name.lower())

    if dual:
        unet_nodes = [n for n in nodes
                      if (n.get("type") or n.get("class_type")) == "UNETLoader"]
        if dual == "t2v":
            files = [WAN_14B_T2V_HI, WAN_14B_T2V_LO]
        else:
            files = [WAN_14B_I2V_HI, WAN_14B_I2V_LO]
        for i, n in enumerate(unet_nodes[:2]):
            patch_unet_loader(n, files[i])
        patch_latent_dims(nodes, WAN_14B_W, WAN_14B_H, WAN_14B_LEN)
    elif ggu:
        for n in nodes:
            patch_unet_loader(n, ggu)
        if "wan2_2_5b" in name.lower():
            patch_latent_dims(nodes, WAN_5B_W, WAN_5B_H, WAN_5B_LEN)
        else:
            patch_latent_dims(nodes, IMG_W, IMG_H, None)
    else:
        patch_latent_dims(nodes, IMG_W, IMG_H, None)

    patch_vae_decode_tiled(nodes, is_video)

    dst.parent.mkdir(parents=True, exist_ok=True)
    with open(dst, "w") as f:
        json.dump(w, f, indent=2)
    return True

count_ok = count_skip = 0
for src in SRC.rglob("*.json"):
    rel = src.relative_to(SRC)
    dst = DST / rel
    if patch_workflow(src, dst):
        count_ok += 1
    else:
        count_skip += 1

print(f"patched: {count_ok}    skipped: {count_skip}")
print(f"output: {DST}")
PY

# ---- summary ----
echo
for d in "${DST}"/*/; do
    [[ -d "$d" ]] || continue
    n=$(find "$d" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    printf "  %-15s %s patched JSONs\n" "$(basename "$d")" "$n"
done

cat <<EOF

Patched workflows at: ${DST}

Drag from there (NOT the unpatched 'workflows/' dir).

What changed per workflow:
  • UNETLoader → UnetLoaderGGUF + correct GGUF filename
  • Latent dims clamped to VRAM-safe values (832x480x33 for Wan 5B,
    480x272x33 for Wan 14B, 1024x1024 for image models)
  • Dual-expert Wan 14B workflows wired to HighNoise + LowNoise GGUFs

If a workflow still complains, screenshot the missing-models panel.
EOF
