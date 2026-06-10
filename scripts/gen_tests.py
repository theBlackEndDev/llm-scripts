#!/usr/bin/env python3
"""Smoke-test new ComfyUI image models: one generation each, save PNGs.
Runs ON the box against the local ComfyUI API (127.0.0.1:8188).
Each graph is hand-built (minimal) from the official-template params.
Goal: prove the model loads + runs end-to-end (image quality secondary)."""
import json, time, urllib.request, sys

API = "http://127.0.0.1:8188"
PROMPT = "a red apple and a small ceramic mug on a wooden table, soft window light, sharp focus"
NEG = "blurry, lowres, watermark, text"

def post(graph):
    data = json.dumps({"prompt": graph}).encode()
    req = urllib.request.Request(f"{API}/prompt", data=data,
                                 headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=20))["prompt_id"]

def wait(pid, timeout=600):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            h = json.load(urllib.request.urlopen(f"{API}/history/{pid}", timeout=10))
        except Exception:
            time.sleep(3); continue
        if pid in h:
            st = h[pid].get("status", {})
            if st.get("completed"):
                imgs = []
                for o in h[pid].get("outputs", {}).values():
                    for im in o.get("images", []):
                        imgs.append(im["filename"])
                return True, imgs, st.get("status_str")
            if st.get("status_str") == "error":
                return False, [], json.dumps(st.get("messages", []))[:300]
        time.sleep(3)
    return False, [], "timeout"

def te(clip, text, nid):
    return {nid: {"class_type": "CLIPTextEncode", "inputs": {"clip": clip, "text": text}}}

# --- per-model minimal graphs ---
def g_chroma(pfx):
    g = {
      "u": {"class_type":"UnetLoaderGGUF","inputs":{"unet_name":"Chroma1-HD-Q4_0.gguf"}},
      "ms":{"class_type":"ModelSamplingAuraFlow","inputs":{"model":["u",0],"shift":1.0}},
      "c": {"class_type":"CLIPLoader","inputs":{"clip_name":"t5xxl_fp8_e4m3fn_scaled.safetensors","type":"chroma"}},
      "v": {"class_type":"VAELoader","inputs":{"vae_name":"ae.safetensors"}},
      "l": {"class_type":"EmptySD3LatentImage","inputs":{"width":1024,"height":1024,"batch_size":1}},
      "k": {"class_type":"KSampler","inputs":{"model":["ms",0],"positive":["p",0],"negative":["n",0],"latent_image":["l",0],"seed":42,"steps":26,"cfg":3.5,"sampler_name":"euler","scheduler":"beta","denoise":1.0}},
      "d": {"class_type":"VAEDecode","inputs":{"samples":["k",0],"vae":["v",0]}},
      "s": {"class_type":"SaveImage","inputs":{"images":["d",0],"filename_prefix":pfx}},
    }
    g.update(te(["c",0],PROMPT,"p")); g.update(te(["c",0],NEG,"n")); return g

def g_hidream(pfx):
    g = {
      "u": {"class_type":"UnetLoaderGGUF","inputs":{"unet_name":"hidream-i1-full-Q5_K_M.gguf"}},
      "c": {"class_type":"QuadrupleCLIPLoader","inputs":{"clip_name1":"clip_l_hidream.safetensors","clip_name2":"clip_g_hidream.safetensors","clip_name3":"t5xxl_fp8_e4m3fn_scaled.safetensors","clip_name4":"llama_3.1_8b_instruct_fp8_scaled.safetensors"}},
      "v": {"class_type":"VAELoader","inputs":{"vae_name":"ae.safetensors"}},
      "l": {"class_type":"EmptySD3LatentImage","inputs":{"width":512,"height":512,"batch_size":1}},
      "k": {"class_type":"KSampler","inputs":{"model":["u",0],"positive":["p",0],"negative":["n",0],"latent_image":["l",0],"seed":42,"steps":28,"cfg":5.0,"sampler_name":"lcm","scheduler":"normal","denoise":1.0}},
      "d": {"class_type":"VAEDecode","inputs":{"samples":["k",0],"vae":["v",0]}},
      "s": {"class_type":"SaveImage","inputs":{"images":["d",0],"filename_prefix":pfx}},
    }
    g.update(te(["c",0],PROMPT,"p")); g.update(te(["c",0],NEG,"n")); return g

def g_qwen2512(pfx):
    g = {
      "u": {"class_type":"UnetLoaderGGUF","inputs":{"unet_name":"qwen-image-2512-Q5_K_M.gguf"}},
      "c": {"class_type":"CLIPLoader","inputs":{"clip_name":"qwen_2.5_vl_7b_fp8_scaled.safetensors","type":"qwen_image"}},
      "v": {"class_type":"VAELoader","inputs":{"vae_name":"qwen_image_vae.safetensors"}},
      "l": {"class_type":"EmptySD3LatentImage","inputs":{"width":512,"height":512,"batch_size":1}},
      "k": {"class_type":"KSampler","inputs":{"model":["u",0],"positive":["p",0],"negative":["n",0],"latent_image":["l",0],"seed":42,"steps":20,"cfg":2.5,"sampler_name":"euler","scheduler":"simple","denoise":1.0}},
      "d": {"class_type":"VAEDecode","inputs":{"samples":["k",0],"vae":["v",0]}},
      "s": {"class_type":"SaveImage","inputs":{"images":["d",0],"filename_prefix":pfx}},
    }
    g.update(te(["c",0],PROMPT,"p")); g.update(te(["c",0],NEG,"n")); return g

TESTS = [
    ("chroma",        "Chroma1-HD (Apache, uncensored)",        PROMPT, g_chroma),
    ("hidream",       "HiDream-I1-Full Q5 (MIT)",               PROMPT, g_hidream),
    ("qwen_image2512","Qwen-Image-2512 Q5 (Apache)",            PROMPT, g_qwen2512),
]

results = []
for key, label, prompt, fn in TESTS:
    pfx = f"verify_{key}"
    print(f"\n=== {label} ===")
    try:
        pid = post(fn(pfx))
    except Exception as e:
        print(f"  SUBMIT FAIL: {str(e)[:200]}"); results.append((key,label,prompt,"SUBMIT_FAIL",[])); continue
    ok, imgs, info = wait(pid)
    print(f"  {'OK' if ok else 'FAIL'} {imgs if ok else info[:200]}")
    results.append((key, label, prompt, "OK" if ok else "FAIL", imgs))

print("\n===SUMMARY===")
for k,l,p,st,im in results:
    print(f"{st:5} | {l} | {im}")
json.dump([{"key":k,"label":l,"prompt":p,"status":st,"images":im} for k,l,p,st,im in results],
          open("/tmp/gen_results.json","w"), indent=2)
print("results -> /tmp/gen_results.json")
