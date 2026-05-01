#!/usr/bin/env python3
"""Generate Wan 2.2 14B dual-expert T2V/I2V workflow JSONs sized for 16GB RAM/VRAM.

Run on Mac:
    python3 gen-wan22-14b-workflow.py

Drops:
    workflows-patched/wan/wan22_14B_t2v_gguf_16gb.json
    workflows-patched/wan/wan22_14B_i2v_gguf_16gb.json
"""
import json, os
from pathlib import Path

OUT = Path.home() / "Projects/llm-scripts/workflows-patched/wan"
OUT.mkdir(parents=True, exist_ok=True)

# ---- stack ----
HIGH_T2V = "HighNoise/Wan2.2-T2V-A14B-HighNoise-Q4_K_M.gguf"
LOW_T2V  = "LowNoise/Wan2.2-T2V-A14B-LowNoise-Q4_K_M.gguf"
HIGH_I2V = "HighNoise/Wan2.2-I2V-A14B-HighNoise-Q4_K_M.gguf"
LOW_I2V  = "LowNoise/Wan2.2-I2V-A14B-LowNoise-Q4_K_M.gguf"
UMT5     = "umt5-xxl-encoder-Q4_K_M.gguf"
VAE      = "wan2.2_vae.safetensors"
LORA_HI  = "wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"
LORA_LO  = "wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"
LORA_I_HI = "wan2.2_i2v_lightx2v_4steps_lora_v1_high_noise.safetensors"
LORA_I_LO = "wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors"

# ---- VRAM-safe defaults (16GB) ----
W, H, FRAMES = 480, 272, 33
TOTAL_STEPS = 8         # 4 hi + 4 lo with lightning LoRAs
HIGH_END_STEP = 4
SHIFT = 8.0
CFG = 1.0
SEED = 0  # randomized in UI

POS_PROMPT = "cinematic shot of a stylish woman walking through a neon-lit alley at night, rain on the ground, slow dolly motion, 35mm film, shallow depth of field"
NEG_PROMPT = "blurry, distorted, low quality, ugly, deformed, watermark, text"


def build_t2v():
    nodes = []
    links = []
    nid = 0
    def add(typ, pos, widgets=None, props=None, inputs=None, outputs=None):
        nonlocal nid
        nid += 1
        n = {
            "id": nid, "type": typ, "pos": pos, "size": [320, 100],
            "flags": {}, "order": nid - 1, "mode": 0,
            "inputs": inputs or [], "outputs": outputs or [],
            "properties": props or {"Node name for S&R": typ},
            "widgets_values": widgets or [],
        }
        nodes.append(n)
        return n

    def link(src_node, src_slot, dst_node, dst_slot, dtype):
        nonlocal links
        lid = len(links) + 1
        links.append([lid, src_node["id"], src_slot, dst_node["id"], dst_slot, dtype])
        # Wire into nodes
        if "outputs" in src_node and len(src_node["outputs"]) > src_slot:
            src_node["outputs"][src_slot].setdefault("links", []).append(lid)
        if dst_slot < len(dst_node["inputs"]):
            dst_node["inputs"][dst_slot]["link"] = lid
        return lid

    # Loaders
    unet_hi = add("UnetLoaderGGUF", [50, 100], widgets=[HIGH_T2V],
                  outputs=[{"name":"MODEL","type":"MODEL","links":[]}])
    unet_lo = add("UnetLoaderGGUF", [50, 220], widgets=[LOW_T2V],
                  outputs=[{"name":"MODEL","type":"MODEL","links":[]}])
    clip = add("CLIPLoaderGGUF", [50, 340], widgets=[UMT5, "wan"],
               outputs=[{"name":"CLIP","type":"CLIP","links":[]}])
    vae = add("VAELoader", [50, 460], widgets=[VAE],
              outputs=[{"name":"VAE","type":"VAE","links":[]}])

    # Lightning LoRAs (4-step distillation)
    lora_hi = add("LoraLoaderModelOnly", [400, 100],
                  widgets=[LORA_HI, 1.0],
                  inputs=[{"name":"model","type":"MODEL","link":None}],
                  outputs=[{"name":"MODEL","type":"MODEL","links":[]}])
    lora_lo = add("LoraLoaderModelOnly", [400, 220],
                  widgets=[LORA_LO, 1.0],
                  inputs=[{"name":"model","type":"MODEL","link":None}],
                  outputs=[{"name":"MODEL","type":"MODEL","links":[]}])
    link(unet_hi, 0, lora_hi, 0, "MODEL")
    link(unet_lo, 0, lora_lo, 0, "MODEL")

    # ModelSamplingSD3 shift
    msm_hi = add("ModelSamplingSD3", [750, 100], widgets=[SHIFT],
                 inputs=[{"name":"model","type":"MODEL","link":None}],
                 outputs=[{"name":"MODEL","type":"MODEL","links":[]}])
    msm_lo = add("ModelSamplingSD3", [750, 220], widgets=[SHIFT],
                 inputs=[{"name":"model","type":"MODEL","link":None}],
                 outputs=[{"name":"MODEL","type":"MODEL","links":[]}])
    link(lora_hi, 0, msm_hi, 0, "MODEL")
    link(lora_lo, 0, msm_lo, 0, "MODEL")

    # Prompts
    pos = add("CLIPTextEncode", [400, 460], widgets=[POS_PROMPT],
              inputs=[{"name":"clip","type":"CLIP","link":None}],
              outputs=[{"name":"CONDITIONING","type":"CONDITIONING","links":[]}])
    neg = add("CLIPTextEncode", [400, 600], widgets=[NEG_PROMPT],
              inputs=[{"name":"clip","type":"CLIP","link":None}],
              outputs=[{"name":"CONDITIONING","type":"CONDITIONING","links":[]}])
    link(clip, 0, pos, 0, "CLIP")
    link(clip, 0, neg, 0, "CLIP")

    # Empty latent
    latent = add("EmptyHunyuanLatentVideo", [750, 460],
                 widgets=[W, H, FRAMES, 1],
                 outputs=[{"name":"LATENT","type":"LATENT","links":[]}])

    # Two-stage KSamplerAdvanced
    ks_hi = add("KSamplerAdvanced", [1100, 100],
                widgets=["enable", SEED, "fixed", TOTAL_STEPS, CFG,
                         "res_multistep", "beta",
                         0, HIGH_END_STEP, "enable"],
                inputs=[
                    {"name":"model","type":"MODEL","link":None},
                    {"name":"positive","type":"CONDITIONING","link":None},
                    {"name":"negative","type":"CONDITIONING","link":None},
                    {"name":"latent_image","type":"LATENT","link":None},
                ],
                outputs=[{"name":"LATENT","type":"LATENT","links":[]}])
    link(msm_hi, 0, ks_hi, 0, "MODEL")
    link(pos,    0, ks_hi, 1, "CONDITIONING")
    link(neg,    0, ks_hi, 2, "CONDITIONING")
    link(latent, 0, ks_hi, 3, "LATENT")

    ks_lo = add("KSamplerAdvanced", [1100, 460],
                widgets=["disable", SEED, "fixed", TOTAL_STEPS, CFG,
                         "res_multistep", "beta",
                         HIGH_END_STEP, TOTAL_STEPS, "disable"],
                inputs=[
                    {"name":"model","type":"MODEL","link":None},
                    {"name":"positive","type":"CONDITIONING","link":None},
                    {"name":"negative","type":"CONDITIONING","link":None},
                    {"name":"latent_image","type":"LATENT","link":None},
                ],
                outputs=[{"name":"LATENT","type":"LATENT","links":[]}])
    link(msm_lo, 0, ks_lo, 0, "MODEL")
    link(pos,    0, ks_lo, 1, "CONDITIONING")
    link(neg,    0, ks_lo, 2, "CONDITIONING")
    link(ks_hi,  0, ks_lo, 3, "LATENT")

    # Tile VAE Decode
    vd = add("VAEDecodeTiled", [1450, 460],
             widgets=[128, 32, 32, 4],
             inputs=[
                 {"name":"samples","type":"LATENT","link":None},
                 {"name":"vae","type":"VAE","link":None},
             ],
             outputs=[{"name":"IMAGE","type":"IMAGE","links":[]}])
    link(ks_lo, 0, vd, 0, "LATENT")
    link(vae,   0, vd, 1, "VAE")

    # Save video (use VHS_VideoCombine for compat)
    save = add("VHS_VideoCombine", [1800, 460],
               widgets={"frame_rate": 16, "loop_count": 0,
                        "filename_prefix": "wan22_14b_t2v",
                        "format": "video/h264-mp4",
                        "pix_fmt": "yuv420p", "crf": 19,
                        "save_metadata": True, "trim_to_audio": False,
                        "pingpong": False, "save_output": True},
               inputs=[{"name":"images","type":"IMAGE","link":None}])
    link(vd, 0, save, 0, "IMAGE")

    return {
        "id": "wan22-14b-t2v-gguf-16gb",
        "revision": 0,
        "last_node_id": nid,
        "last_link_id": len(links),
        "nodes": nodes,
        "links": links,
        "groups": [],
        "config": {},
        "extra": {},
        "version": 0.4,
    }


def build_i2v():
    """Same skeleton as T2V but with image conditioning input."""
    wf = build_t2v()
    # Swap models to I2V
    for n in wf["nodes"]:
        if n.get("type") == "UnetLoaderGGUF":
            wv = n.get("widgets_values", [])
            if wv and wv[0] == HIGH_T2V: wv[0] = HIGH_I2V
            elif wv and wv[0] == LOW_T2V: wv[0] = LOW_I2V
        if n.get("type") == "LoraLoaderModelOnly":
            wv = n.get("widgets_values", [])
            if wv and wv[0] == LORA_HI: wv[0] = LORA_I_HI
            elif wv and wv[0] == LORA_LO: wv[0] = LORA_I_LO
    # NOTE: Adding a proper LoadImage + WanImageToVideo encoder is a manual step
    # in ComfyUI for I2V. Replace EmptyHunyuanLatentVideo with WanImageToVideo node.
    return wf


for name, builder in [("wan22_14B_t2v_gguf_16gb", build_t2v),
                      ("wan22_14B_i2v_gguf_16gb", build_i2v)]:
    out = OUT / f"{name}.json"
    with open(out, "w") as f:
        json.dump(builder(), f, indent=2)
    print(f"wrote: {out}")
