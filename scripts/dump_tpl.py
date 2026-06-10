#!/usr/bin/env python3
"""Dump node types + widget values + sampler params from ComfyUI UI templates,
so we can hand-build correct API graphs. Runs on the box."""
import json, glob, os

DIRS = [
    "/opt/comfyui/.venv/lib/python3.12/site-packages/comfyui_workflow_templates_media_image/templates",
    "/opt/comfyui/.venv/lib/python3.12/site-packages/comfyui_workflow_templates_media_video/templates",
    "/opt/comfyui/.venv/lib/python3.12/site-packages/comfyui_workflow_templates/templates",
]

WANT = ["image_ideogram4_t2i", "image_qwen_image_edit_2511", "mochi", "wan2_2_animate", "wan_animate"]

def find(name):
    for d in DIRS:
        for p in glob.glob(f"{d}/*{name}*.json"):
            return p
    return None

for w in WANT:
    p = find(w)
    if not p:
        print(f"\n### {w}: NOT FOUND"); continue
    d = json.load(open(p))
    print(f"\n### {w}  ({os.path.basename(p)})")
    for n in d.get("nodes", []):
        t = n.get("type", "")
        if t in ("Note", "MarkdownNote", "Reroute"):
            continue
        wv = n.get("widgets_values", [])
        # trim long text
        wv = [(x[:40] + "…") if isinstance(x, str) and len(x) > 40 else x for x in wv]
        print(f"  {t}: {wv}")
