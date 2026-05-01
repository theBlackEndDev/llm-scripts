#!/usr/bin/env bash
# Videogen pipeline package — orchestrates ComfyUI + GPT-SoVITS + Ollama + ffmpeg
# Installs to /opt/videogen with Justfile + Python orchestrator.

set -euo pipefail

readonly INSTALL_DIR="/opt/videogen"
readonly SERVICE_USER="videogen"

log() { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run with sudo."

# ---- deps ----
log "Deps"
apt-get update
apt-get install -y --no-install-recommends \
    python3.11 python3.11-venv python3-pip \
    ffmpeg curl jq just tmux git

# ---- service user (real user, login enabled — owns projects) ----
log "User '${SERVICE_USER}'"
if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${SERVICE_USER}"
fi

# ---- skeleton ----
log "Building skeleton at ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"/{pipeline/{stages,lib},workflows,projects,scripts,loras/{watchlists,registry}}
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"

# ---- venv ----
log "Python venv + libs"
sudo -u "${SERVICE_USER}" bash <<'EOF'
set -euo pipefail
cd /opt/videogen
python3.11 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip wheel
pip install requests websocket-client tomli tomli-w pillow rich typer
EOF

# ---- config.toml ----
log "config.toml"
sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/config.toml" >/dev/null <<'EOF'
[hosts]
comfyui     = "http://127.0.0.1:8188"
ollama      = "http://127.0.0.1:11434"
sovits_api  = "http://127.0.0.1:9880"   # gpt-sovits api server (optional)
whisper     = "http://127.0.0.1:9000"

[models]
script_llm   = "qwen2.5:9b"
tts_model    = "v4"
wan_quant    = "Q5_K_M"

[render]
default_resolution = "832x480"   # FoxtonAI sweet spot for sub-32GB
default_fps        = 16
default_steps      = 22
default_clip_secs  = 5
upscale_factor     = 2
interpolate_to_fps = 32

[workflows]
# video — primary: LTX 2.3 (fast, audio). secondary: Wan 2.2 (motion realism)
ltx_t2v        = "ltx23_t2v.json"
ltx_i2v        = "ltx23_i2v.json"
ltx_lipsync    = "ltx23_lipsync.json"      # talking-head with synced lips (LTX Lip-Sync LoRA)
wan_t2v        = "wan22_t2v.json"
wan_i2v        = "wan22_i2v.json"
wan_flf2v      = "wan22_flf2v.json"
wan_5b_turbo   = "wan22_5b_turbo.json"     # native 1440p, 4-step turbo
# legacy aliases (used by 03_render.py)
t2v        = "ltx23_t2v.json"
i2v        = "ltx23_i2v.json"
flf2v      = "wan22_flf2v.json"
# image
flux_t2i        = "flux2_t2i.json"            # primary: FLUX.2 Dev (top tier 2026)
flux_krea_t2i   = "flux_krea_t2i.json"        # alt: Krea (skin specialist)
qwen_image_t2i  = "qwen_image_t2i.json"       # alt: Qwen-Image-2512 (different aesthetic)
sdxl_t2i        = "sdxl_t2i.json"             # alt: SDXL (fast iter, LoRA library)
# music
music_ace      = "music_ace_step.json"
music_musicgen = "music_musicgen.json"
# audio post (add SFX/ambient to existing video)
foley          = "hunyuan_foley.json"
# TTS
indextts2      = "indextts2.json"             # zero-shot voice + emotion control

[render.video_engine]
# "ltx" (fast, audio) or "wan" (better motion). Pipeline picks workflow accordingly.
default = "ltx"

[paths]
projects   = "/opt/videogen/projects"
workflows  = "/opt/videogen/workflows"
EOF

# ---- ComfyUI client lib ----
log "Pipeline libs"
sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/lib/__init__.py" >/dev/null <<'EOF'
EOF

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/lib/comfy_client.py" >/dev/null <<'PY'
"""Minimal ComfyUI API client: queue prompt, wait, fetch outputs."""
import json, time, uuid, os
import requests
import websocket


class ComfyClient:
    def __init__(self, base_url: str):
        self.base = base_url.rstrip("/")
        self.cid = str(uuid.uuid4())

    def queue(self, workflow: dict) -> str:
        r = requests.post(f"{self.base}/prompt",
                          json={"prompt": workflow, "client_id": self.cid},
                          timeout=30)
        r.raise_for_status()
        return r.json()["prompt_id"]

    def wait(self, prompt_id: str, timeout: int = 3600) -> dict:
        ws_url = self.base.replace("http", "ws") + f"/ws?clientId={self.cid}"
        ws = websocket.WebSocket()
        ws.connect(ws_url, timeout=10)
        deadline = time.time() + timeout
        try:
            while time.time() < deadline:
                msg = ws.recv()
                if not isinstance(msg, str):
                    continue
                evt = json.loads(msg)
                if evt.get("type") == "executing":
                    d = evt.get("data") or {}
                    if d.get("node") is None and d.get("prompt_id") == prompt_id:
                        break
        finally:
            ws.close()
        h = requests.get(f"{self.base}/history/{prompt_id}", timeout=30).json()
        return h.get(prompt_id, {})

    def download_output(self, item: dict, out_dir: str) -> str:
        params = {
            "filename": item["filename"],
            "subfolder": item.get("subfolder", ""),
            "type":      item.get("type", "output"),
        }
        r = requests.get(f"{self.base}/view", params=params, stream=True, timeout=120)
        r.raise_for_status()
        os.makedirs(out_dir, exist_ok=True)
        path = os.path.join(out_dir, item["filename"])
        with open(path, "wb") as f:
            for chunk in r.iter_content(8192):
                f.write(chunk)
        return path

    def collect_outputs(self, history: dict, out_dir: str) -> list[str]:
        out = []
        for node_id, node_out in (history.get("outputs") or {}).items():
            for key in ("gifs", "videos", "images"):
                for item in node_out.get(key, []) or []:
                    out.append(self.download_output(item, out_dir))
        return out
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/lib/config.py" >/dev/null <<'PY'
import tomli, os
from pathlib import Path

ROOT = Path("/opt/videogen")
CONFIG_PATH = ROOT / "pipeline" / "config.toml"

def load() -> dict:
    with open(CONFIG_PATH, "rb") as f:
        return tomli.load(f)

def project_dir(slug: str) -> Path:
    p = ROOT / "projects" / slug
    p.mkdir(parents=True, exist_ok=True)
    return p
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/lib/civitai.py" >/dev/null <<'PY'
"""Civitai API client + LoRA curator/installer.

API base: https://civitai.com/api/v1
Auth: optional CIVITAI_API_KEY env var (Bronze tier+ for early-access).

Quality score formula:
    score = log10(downloads+1) * 0.4
          + (rating / 5)       * 0.3
          + recency_bonus      * 0.2
          + commercial_ok      * 0.1
"""
import os, json, hashlib, time, math, re
from pathlib import Path
from datetime import datetime
import requests

API = "https://civitai.com/api/v1"
COMFY_LORAS = Path("/opt/comfyui/models/loras")
REGISTRY = Path("/opt/videogen/loras/registry/registry.json")

# Map our categories -> Civitai filter params
CATEGORIES = {
    "video/motion-wan22":    dict(types="LORA", baseModel="Wan Video", tag="motion"),
    "video/character-wan22": dict(types="LORA", baseModel="Wan Video", tag="character"),
    "video/style-wan22":     dict(types="LORA", baseModel="Wan Video", tag="style"),
    "video/lipsync-ltx23":   dict(types="LORA", baseModel="LTX-Video", tag="lipsync"),
    "image/photoreal-flux":  dict(types="LORA", baseModel="Flux.1 D",  tag="photorealistic"),
    "image/style-flux":      dict(types="LORA", baseModel="Flux.1 D",  tag="style"),
    "image/photoreal-sdxl":  dict(types="LORA", baseModel="SDXL 1.0",  tag="photorealistic"),
    "image/detail-sdxl":     dict(types="LORA", baseModel="SDXL 1.0",  tag="detail"),
}

# Risky tags / signals to filter out
BLOCKLIST_TAGS = {"celebrity", "actress", "actor", "real person",
                  "minor", "child", "underage"}
BLOCKLIST_NAME_PATTERNS = [
    re.compile(r"\b(taylor swift|elon|trump|biden)\b", re.I),
]

def _headers():
    h = {"Accept": "application/json"}
    key = os.environ.get("CIVITAI_API_KEY")
    if key:
        h["Authorization"] = f"Bearer {key}"
    return h

def search(category: str, limit: int = 50, period: str = "Month") -> list[dict]:
    """Query Civitai for top LoRAs in a category."""
    if category not in CATEGORIES:
        raise ValueError(f"unknown category: {category}")
    params = dict(CATEGORIES[category])
    params.update(limit=limit, sort="Most Downloaded", period=period, nsfw="false")
    r = requests.get(f"{API}/models", params=params, headers=_headers(), timeout=30)
    r.raise_for_status()
    return r.json().get("items", [])

def _commercial_ok(model: dict) -> bool:
    p = model.get("allowCommercialUse") or []
    if isinstance(p, str): p = [p]
    return "Sell" in p or "RentCivit" in p or "Image" in p or "Rent" in p

def _has_blocked_terms(model: dict) -> bool:
    name = (model.get("name") or "") + " " + (model.get("description") or "")
    if any(p.search(name) for p in BLOCKLIST_NAME_PATTERNS):
        return True
    tags = {t.lower() for t in (model.get("tags") or [])}
    return bool(tags & BLOCKLIST_TAGS)

def _score(model: dict) -> float:
    stats = model.get("stats") or {}
    downloads = stats.get("downloadCount", 0)
    rating = stats.get("rating", 0)
    rating_count = stats.get("ratingCount", 0)
    if rating_count < 5:
        rating = 3.0  # uncertain, pull to neutral
    updated = model.get("updatedAt") or model.get("createdAt")
    age_days = 30
    if updated:
        try:
            age_days = (datetime.utcnow() - datetime.fromisoformat(updated.replace("Z", ""))).days or 1
        except Exception:
            pass
    recency = max(0.0, 1.0 - math.log10(age_days + 1) / 3)
    commercial = 1.0 if _commercial_ok(model) else 0.0
    return (math.log10(downloads + 1) * 0.4
            + (rating / 5)            * 0.3
            + recency                 * 0.2
            + commercial              * 0.1)

def rank(category: str, limit: int = 30) -> list[dict]:
    """Return top LoRAs in a category, ranked + filtered."""
    items = search(category, limit=limit * 2)
    out = []
    for m in items:
        if _has_blocked_terms(m):
            continue
        # find the latest version with a .safetensors file
        versions = m.get("modelVersions") or []
        for v in versions:
            files = v.get("files") or []
            sft = next((f for f in files
                        if f.get("name", "").endswith(".safetensors")
                        and f.get("metadata", {}).get("format", "SafeTensor") != "PickleTensor"), None)
            if sft:
                out.append({
                    "id": m["id"],
                    "name": m["name"],
                    "score": round(_score(m), 3),
                    "downloads": (m.get("stats") or {}).get("downloadCount", 0),
                    "rating": (m.get("stats") or {}).get("rating", 0),
                    "commercial": _commercial_ok(m),
                    "url": f"https://civitai.com/models/{m['id']}",
                    "version_id": v["id"],
                    "file_url": sft["downloadUrl"],
                    "file_name": sft["name"],
                    "file_sha256": (sft.get("hashes") or {}).get("SHA256"),
                    "file_size_kb": sft.get("sizeKB", 0),
                    "trigger_words": v.get("trainedWords") or [],
                    "base_model": v.get("baseModel"),
                    "license": m.get("license"),
                })
                break
    out.sort(key=lambda x: x["score"], reverse=True)
    return out[:limit]

def _load_registry() -> dict:
    if REGISTRY.exists():
        return json.loads(REGISTRY.read_text())
    return {"installed": {}}

def _save_registry(reg: dict):
    REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    REGISTRY.write_text(json.dumps(reg, indent=2))

def install(entry: dict, category: str) -> Path:
    """Download + verify + log a LoRA. Returns local path."""
    base_dir = COMFY_LORAS / category.replace("/", "_")
    base_dir.mkdir(parents=True, exist_ok=True)
    target = base_dir / entry["file_name"]
    if target.exists():
        print(f"[skip] {target.name} already present")
    else:
        print(f"[get] {entry['name']} -> {target}")
        with requests.get(entry["file_url"], stream=True, headers=_headers(),
                          allow_redirects=True, timeout=600) as r:
            r.raise_for_status()
            with open(target, "wb") as f:
                for chunk in r.iter_content(8192):
                    f.write(chunk)
        # verify SHA256 if known
        if entry.get("file_sha256"):
            h = hashlib.sha256(target.read_bytes()).hexdigest().upper()
            if h != entry["file_sha256"].upper():
                target.unlink()
                raise RuntimeError(f"SHA256 mismatch on {entry['file_name']}")
            print(f"   sha256 ok")
    # log to registry
    reg = _load_registry()
    reg["installed"][str(target)] = {
        "civitai_id":    entry["id"],
        "civitai_url":   entry["url"],
        "name":          entry["name"],
        "category":      category,
        "trigger_words": entry["trigger_words"],
        "base_model":    entry["base_model"],
        "license":       entry["license"],
        "commercial":    entry["commercial"],
        "sha256":        entry["file_sha256"],
        "installed_at":  datetime.utcnow().isoformat() + "Z",
    }
    _save_registry(reg)
    return target

def list_installed() -> list[dict]:
    reg = _load_registry()
    return [{"path": p, **meta} for p, meta in reg["installed"].items()]
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/lib/ollama_client.py" >/dev/null <<'PY'
import requests

def chat(base: str, model: str, system: str, user: str, max_tokens: int = 2000) -> str:
    r = requests.post(f"{base}/v1/chat/completions",
        json={
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user",   "content": user},
            ],
            "max_tokens": max_tokens,
            "temperature": 0.7,
        },
        timeout=600,
    )
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]
PY

# ---- stages ----
log "Pipeline stages"

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/01_script.py" >/dev/null <<'PY'
"""Draft script via local Qwen. Output: projects/<slug>/script.md"""
import sys
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config, ollama_client

def main(slug: str, topic: str, duration_seconds: int = 90):
    cfg = config.load()
    pdir = config.project_dir(slug)
    sys_prompt = (
        "You write tight, conversational YouTube narration scripts. "
        "Plain prose only. No headers, no bullet points. "
        "Target spoken pacing: ~150 wpm."
    )
    target_words = int(duration_seconds * 150 / 60)
    user = f"Topic: {topic}\nTarget length: ~{target_words} words ({duration_seconds}s spoken).\nWrite the script."
    text = ollama_client.chat(cfg["hosts"]["ollama"], cfg["models"]["script_llm"], sys_prompt, user)
    out = pdir / "script.md"
    out.write_text(text.strip() + "\n")
    print(f"[ok] {out}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: 01_script.py <slug> <topic> [seconds]")
        sys.exit(1)
    secs = int(sys.argv[3]) if len(sys.argv) > 3 else 90
    main(sys.argv[1], sys.argv[2], secs)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/02_storyboard.py" >/dev/null <<'PY'
"""Split script into shotlist (per-clip prompts). Output: projects/<slug>/shots.toml"""
import sys, json, re
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config, ollama_client
import tomli_w

def main(slug: str, clip_secs: int = 5):
    cfg = config.load()
    pdir = config.project_dir(slug)
    script = (pdir / "script.md").read_text()
    sys_prompt = (
        "Convert the following narration into a sequential shot list for a video. "
        "Each shot should be ~{secs} seconds. "
        "Output strict JSON: a list of objects with keys: "
        "id (zero-padded 02d), prompt (visual description, NO dialogue, NO text-on-screen), "
        "narration (text spoken during this shot), seconds (int)."
    ).format(secs=clip_secs)
    raw = ollama_client.chat(cfg["hosts"]["ollama"], cfg["models"]["script_llm"], sys_prompt, script, max_tokens=4000)
    m = re.search(r"\[.*\]", raw, re.DOTALL)
    if not m:
        raise RuntimeError(f"no JSON list in LLM output:\n{raw}")
    shots = json.loads(m.group(0))
    out = pdir / "shots.toml"
    with open(out, "wb") as f:
        tomli_w.dump({"shots": shots}, f)
    print(f"[ok] {out}  ({len(shots)} shots)")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: 02_storyboard.py <slug> [clip_secs]")
        sys.exit(1)
    secs = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    main(sys.argv[1], secs)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/03_render.py" >/dev/null <<'PY'
"""Render shots via ComfyUI. Uses T2V for shot 0, FLF2V chain after.
Workflow JSONs must exist in /opt/videogen/workflows/ — export from ComfyUI UI.
Each workflow is expected to have placeholders: __PROMPT__, __SEED__, __FRAMES__, __WIDTH__, __HEIGHT__, __FPS__, __FIRST_FRAME__, __LAST_FRAME__.
"""
import sys, json, random, tomli, shutil, subprocess
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config
from lib.comfy_client import ComfyClient

def load_wf(path: Path, replacements: dict) -> dict:
    raw = path.read_text()
    for k, v in replacements.items():
        raw = raw.replace(k, str(v))
    return json.loads(raw)

def extract_last_frame(video: Path, out_png: Path):
    subprocess.run(
        ["ffmpeg", "-y", "-sseof", "-0.1", "-i", str(video),
         "-update", "1", "-frames:v", "1", str(out_png)],
        check=True, capture_output=True,
    )

def main(slug: str, only_shot: str = None):
    cfg = config.load()
    pdir = config.project_dir(slug)
    shots = tomli.loads((pdir / "shots.toml").read_text())["shots"]
    out_dir = pdir / "01_clips"
    out_dir.mkdir(exist_ok=True)
    last_frames_dir = pdir / "01_clips" / "_last_frames"
    last_frames_dir.mkdir(exist_ok=True)

    client = ComfyClient(cfg["hosts"]["comfyui"])
    wf_dir  = Path(cfg["paths"]["workflows"])
    res     = cfg["render"]["default_resolution"].split("x")
    width, height = int(res[0]), int(res[1])
    fps     = cfg["render"]["default_fps"]

    prev_last = None
    for i, shot in enumerate(shots):
        sid = shot["id"]
        if only_shot and sid != only_shot:
            if (out_dir / f"shot_{sid}.mp4").exists():
                prev_last = last_frames_dir / f"shot_{sid}_last.png"
                if not prev_last.exists():
                    extract_last_frame(out_dir / f"shot_{sid}.mp4", prev_last)
            continue
        secs   = int(shot.get("seconds", cfg["render"]["default_clip_secs"]))
        frames = secs * fps
        seed   = random.randint(1, 2**31 - 1)

        if i == 0 or prev_last is None:
            wf_path = wf_dir / cfg["workflows"]["t2v"]
            replacements = {
                "__PROMPT__": shot["prompt"], "__SEED__": seed,
                "__FRAMES__": frames, "__WIDTH__": width, "__HEIGHT__": height,
                "__FPS__": fps,
            }
        else:
            wf_path = wf_dir / cfg["workflows"]["i2v"]
            replacements = {
                "__PROMPT__": shot["prompt"], "__SEED__": seed,
                "__FRAMES__": frames, "__WIDTH__": width, "__HEIGHT__": height,
                "__FPS__": fps, "__FIRST_FRAME__": str(prev_last),
            }

        if not wf_path.exists():
            print(f"[warn] workflow missing: {wf_path}  — skipping shot {sid}")
            print(f"        export your workflow from ComfyUI UI and save as {wf_path.name}")
            continue

        print(f"[render] shot {sid}  ({secs}s @ {width}x{height})  prompt={shot['prompt'][:60]}...")
        wf = load_wf(wf_path, replacements)
        pid = client.queue(wf)
        history = client.wait(pid)
        outs = client.collect_outputs(history, str(out_dir))
        # pick first .mp4 / .webm output
        videos = [o for o in outs if o.endswith((".mp4", ".webm", ".gif"))]
        if not videos:
            print(f"[warn] no video output for shot {sid}: {outs}")
            continue
        final = out_dir / f"shot_{sid}.mp4"
        shutil.move(videos[0], final)
        prev_last = last_frames_dir / f"shot_{sid}_last.png"
        extract_last_frame(final, prev_last)
        print(f"   -> {final}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: 03_render.py <slug> [shot_id]")
        sys.exit(1)
    only = sys.argv[2] if len(sys.argv) > 2 else None
    main(sys.argv[1], only)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/04_interpolate.py" >/dev/null <<'PY'
"""RIFE-style frame interpolation via ffmpeg minterpolate (CPU fallback).
For ComfyUI-side RIFE, use a render workflow that bakes it in."""
import sys, subprocess
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config

def main(slug: str):
    cfg = config.load()
    pdir = config.project_dir(slug)
    src  = pdir / "01_clips"
    dst  = pdir / "02_interpolated"
    dst.mkdir(exist_ok=True)
    target_fps = cfg["render"]["interpolate_to_fps"]
    for clip in sorted(src.glob("shot_*.mp4")):
        out = dst / clip.name
        print(f"[interp] {clip.name} -> {target_fps}fps")
        subprocess.run([
            "ffmpeg", "-y", "-i", str(clip),
            "-vf", f"minterpolate=fps={target_fps}:mi_mode=mci:mc_mode=aobmc:vsbmc=1",
            "-c:v", "libx264", "-crf", "16", "-preset", "fast", str(out),
        ], check=True, capture_output=True)
    print(f"[ok] {dst}")

if __name__ == "__main__":
    main(sys.argv[1])
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/05_upscale.py" >/dev/null <<'PY'
"""Upscale via ffmpeg lanczos (fast, CPU). Replace with Real-ESRGAN node in ComfyUI for higher quality."""
import sys, subprocess
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config

def main(slug: str, target_w: int = 1920, target_h: int = 1080):
    cfg = config.load()
    pdir = config.project_dir(slug)
    src  = pdir / "02_interpolated"
    if not src.exists():
        src = pdir / "01_clips"
    dst  = pdir / "03_upscaled"
    dst.mkdir(exist_ok=True)
    for clip in sorted(src.glob("shot_*.mp4")):
        out = dst / clip.name
        print(f"[upscale] {clip.name} -> {target_w}x{target_h}")
        subprocess.run([
            "ffmpeg", "-y", "-i", str(clip),
            "-vf", f"scale={target_w}:{target_h}:flags=lanczos",
            "-c:v", "libx264", "-crf", "16", "-preset", "fast", str(out),
        ], check=True, capture_output=True)
    print(f"[ok] {dst}")

if __name__ == "__main__":
    target_w = int(sys.argv[2]) if len(sys.argv) > 2 else 1920
    target_h = int(sys.argv[3]) if len(sys.argv) > 3 else 1080
    main(sys.argv[1], target_w, target_h)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/06_voice.py" >/dev/null <<'PY'
"""Generate per-shot narration via GPT-SoVITS API. Falls back to a stub if API not running.
GPT-SoVITS 'api_v2' or 'api' server must be started separately:
  cd /opt/GPT-SoVITS && .venv/bin/python api_v2.py
"""
import sys, requests, tomli
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config

def main(slug: str, ref_wav: str, ref_text: str):
    cfg  = config.load()
    pdir = config.project_dir(slug)
    shots = tomli.loads((pdir / "shots.toml").read_text())["shots"]
    out_dir = pdir / "04_audio"
    out_dir.mkdir(exist_ok=True)
    for s in shots:
        text = s.get("narration", "").strip()
        if not text:
            continue
        out = out_dir / f"shot_{s['id']}.wav"
        print(f"[tts] shot {s['id']}: {text[:60]}...")
        r = requests.post(
            cfg["hosts"]["sovits_api"] + "/tts",
            json={
                "text": text, "text_lang": "en",
                "ref_audio_path": ref_wav, "prompt_text": ref_text, "prompt_lang": "en",
                "media_type": "wav", "streaming_mode": False,
            },
            timeout=600,
        )
        r.raise_for_status()
        out.write_bytes(r.content)
    print(f"[ok] {out_dir}")

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("usage: 06_voice.py <slug> <ref_wav> <ref_text>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/08_thumbnail.py" >/dev/null <<'PY'
"""Generate YouTube thumbnail (1920x1080) via Flux Krea."""
import sys, json, random, shutil
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config
from lib.comfy_client import ComfyClient

def main(slug: str, prompt: str, model: str = "flux"):
    cfg = config.load()
    pdir = config.project_dir(slug)
    out_dir = pdir / "thumbnails"
    out_dir.mkdir(exist_ok=True)
    wf_key = "flux_t2i" if model == "flux" else "sdxl_t2i"
    wf_path = Path(cfg["paths"]["workflows"]) / cfg["workflows"][wf_key]
    if not wf_path.exists():
        print(f"[err] workflow missing: {wf_path}")
        print(f"      export from ComfyUI UI (API Format) and save it there")
        return
    raw = wf_path.read_text()
    seed = random.randint(1, 2**31 - 1)
    raw = raw.replace("__PROMPT__", prompt).replace("__SEED__", str(seed))
    raw = raw.replace("__WIDTH__", "1920").replace("__HEIGHT__", "1080")
    client = ComfyClient(cfg["hosts"]["comfyui"])
    pid = client.queue(json.loads(raw))
    history = client.wait(pid)
    outs = client.collect_outputs(history, str(out_dir))
    images = [o for o in outs if o.endswith((".png", ".jpg", ".webp"))]
    if images:
        latest = out_dir / "thumbnail.png"
        shutil.copy(images[-1], latest)
        print(f"[ok] {latest}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: 08_thumbnail.py <slug> <prompt> [flux|sdxl]")
        sys.exit(1)
    model = sys.argv[3] if len(sys.argv) > 3 else "flux"
    main(sys.argv[1], sys.argv[2], model)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/09_storyboard_imgs.py" >/dev/null <<'PY'
"""Generate one reference still per shot via Flux/SDXL.
Used as I2V starting frame for higher-quality video gen than pure T2V.
Output: projects/<slug>/storyboard/shot_<id>.png
"""
import sys, json, random, shutil, tomli
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config
from lib.comfy_client import ComfyClient

def main(slug: str, model: str = "flux"):
    cfg = config.load()
    pdir = config.project_dir(slug)
    shots = tomli.loads((pdir / "shots.toml").read_text())["shots"]
    out_dir = pdir / "storyboard"
    out_dir.mkdir(exist_ok=True)
    wf_key = "flux_t2i" if model == "flux" else "sdxl_t2i"
    wf_path = Path(cfg["paths"]["workflows"]) / cfg["workflows"][wf_key]
    if not wf_path.exists():
        print(f"[err] workflow missing: {wf_path}")
        return
    raw_template = wf_path.read_text()
    res = cfg["render"]["default_resolution"].split("x")
    w, h = res[0], res[1]
    client = ComfyClient(cfg["hosts"]["comfyui"])
    for shot in shots:
        sid = shot["id"]
        target = out_dir / f"shot_{sid}.png"
        if target.exists():
            print(f"[skip] {target.name} exists")
            continue
        seed = random.randint(1, 2**31 - 1)
        raw = (raw_template
               .replace("__PROMPT__", shot["prompt"])
               .replace("__SEED__", str(seed))
               .replace("__WIDTH__", w).replace("__HEIGHT__", h))
        print(f"[img] shot {sid}: {shot['prompt'][:60]}...")
        pid = client.queue(json.loads(raw))
        history = client.wait(pid)
        outs = client.collect_outputs(history, str(out_dir))
        images = [o for o in outs if o.endswith((".png", ".jpg", ".webp"))]
        if images:
            shutil.move(images[-1], target)
            print(f"   -> {target}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: 09_storyboard_imgs.py <slug> [flux|sdxl]")
        sys.exit(1)
    model = sys.argv[2] if len(sys.argv) > 2 else "flux"
    main(sys.argv[1], model)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/20_lora.py" >/dev/null <<'PY'
"""LoRA management via Civitai. Subcommands: search, install, list, refresh.

Examples:
    20_lora.py search video/motion-wan22
    20_lora.py install <civitai_url_or_id> [category]
    20_lora.py install-top <category> [n=5]
    20_lora.py list
    20_lora.py categories
"""
import sys, json, re
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import civitai

def cmd_categories():
    for k in civitai.CATEGORIES:
        print(f"  {k}")

def cmd_search(category: str, limit: int = 20):
    ranked = civitai.rank(category, limit=limit)
    if not ranked:
        print(f"no results for {category}")
        return
    print(f"\nTop {len(ranked)} LoRAs for {category} (sorted by score):\n")
    for i, e in enumerate(ranked, 1):
        flag = " " if e["commercial"] else "!"  # ! = no commercial
        print(f"  [{flag}] {i:2d}. {e['name'][:55]:55s}  score={e['score']:.2f}  dl={e['downloads']:>7}  id={e['id']}")
        if e["trigger_words"]:
            print(f"        triggers: {', '.join(e['trigger_words'][:5])}")
        print(f"        {e['url']}")
    print()
    print("[!] = does NOT allow commercial use of generated images. Avoid for monetized YouTube.")

def cmd_install(arg: str, category: str = None):
    # accept full URL, /models/<id>, or just id
    m = re.search(r"models/(\d+)", arg) or re.search(r"^(\d+)$", arg)
    if not m:
        print("usage: install <civitai_url_or_model_id> [category]")
        return
    mid = m.group(1)
    # need a category to file it
    if not category:
        print("Need category. Available:")
        cmd_categories()
        return
    # fetch model details to get latest .safetensors version
    import requests
    r = requests.get(f"{civitai.API}/models/{mid}", headers=civitai._headers(), timeout=30)
    r.raise_for_status()
    model = r.json()
    if civitai._has_blocked_terms(model):
        print(f"[blocked] {model['name']} matched blocklist (celebrity/likeness/risky)")
        return
    versions = model.get("modelVersions") or []
    for v in versions:
        files = v.get("files") or []
        sft = next((f for f in files if f.get("name", "").endswith(".safetensors")), None)
        if sft:
            entry = {
                "id": model["id"], "name": model["name"],
                "score": civitai._score(model),
                "downloads": (model.get("stats") or {}).get("downloadCount", 0),
                "rating":    (model.get("stats") or {}).get("rating", 0),
                "commercial": civitai._commercial_ok(model),
                "url": f"https://civitai.com/models/{model['id']}",
                "version_id": v["id"], "file_url": sft["downloadUrl"],
                "file_name": sft["name"],
                "file_sha256": (sft.get("hashes") or {}).get("SHA256"),
                "trigger_words": v.get("trainedWords") or [],
                "base_model": v.get("baseModel"),
                "license": model.get("license"),
            }
            path = civitai.install(entry, category)
            print(f"[ok] installed: {path}")
            if entry["trigger_words"]:
                print(f"     triggers: {', '.join(entry['trigger_words'])}")
            if not entry["commercial"]:
                print("     [!] commercial use NOT allowed by license")
            return
    print(f"no .safetensors version found for model {mid}")

def cmd_install_top(category: str, n: int = 5):
    ranked = civitai.rank(category, limit=n * 2)
    installed = 0
    for e in ranked:
        if not e["commercial"]:
            continue  # skip non-commercial for monetized YT safety
        try:
            civitai.install(e, category)
            installed += 1
            if installed >= n:
                break
        except Exception as ex:
            print(f"  fail: {e['name']}: {ex}")
    print(f"installed {installed} commercial-OK LoRAs in {category}")

def cmd_list():
    items = civitai.list_installed()
    if not items:
        print("no LoRAs installed via this tool")
        return
    by_cat = {}
    for x in items:
        by_cat.setdefault(x.get("category", "?"), []).append(x)
    for cat, items in sorted(by_cat.items()):
        print(f"\n{cat}:")
        for x in items:
            flag = " " if x.get("commercial") else "!"
            triggers = ", ".join(x.get("trigger_words") or [])
            print(f"  [{flag}] {x['name']}")
            print(f"        triggers: {triggers}")
            print(f"        {x['path']}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "categories":
        cmd_categories()
    elif cmd == "search":
        cmd_search(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 20)
    elif cmd == "install":
        cmd_install(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    elif cmd == "install-top":
        cmd_install_top(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5)
    elif cmd == "list":
        cmd_list()
    else:
        print(f"unknown subcommand: {cmd}")
        print(__doc__)
        sys.exit(1)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/11_foley.py" >/dev/null <<'PY'
"""Hunyuan-Foley: add ambient/SFX audio to a video clip post-gen.
Use when source model (Wan 2.2) didn't produce audio.
"""
import sys, json, random, shutil
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config
from lib.comfy_client import ComfyClient

def main(slug: str, prompt: str = "ambient", clip_id: str = None):
    cfg = config.load()
    pdir = config.project_dir(slug)
    src = pdir / "01_clips"
    out_dir = pdir / "06_foley"
    out_dir.mkdir(exist_ok=True)
    wf_path = Path(cfg["paths"]["workflows"]) / cfg["workflows"]["foley"]
    if not wf_path.exists():
        print(f"[err] workflow missing: {wf_path}")
        return
    targets = sorted(src.glob("shot_*.mp4")) if not clip_id else [src / f"shot_{clip_id}.mp4"]
    client = ComfyClient(cfg["hosts"]["comfyui"])
    for clip in targets:
        if not clip.exists():
            print(f"[skip] {clip.name} missing")
            continue
        seed = random.randint(1, 2**31 - 1)
        raw = (wf_path.read_text()
               .replace("__INPUT_VIDEO__", str(clip))
               .replace("__PROMPT__", prompt)
               .replace("__SEED__", str(seed)))
        print(f"[foley] {clip.name}: {prompt[:60]}")
        pid = client.queue(json.loads(raw))
        history = client.wait(pid, timeout=900)
        outs = client.collect_outputs(history, str(out_dir))
        videos = [o for o in outs if o.endswith((".mp4", ".webm"))]
        if videos:
            target = out_dir / clip.name
            shutil.move(videos[-1], target)
            print(f"   -> {target}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: 11_foley.py <slug> [prompt='ambient'] [shot_id]")
        sys.exit(1)
    prompt  = sys.argv[2] if len(sys.argv) > 2 else "ambient natural sound"
    clip_id = sys.argv[3] if len(sys.argv) > 3 else None
    main(sys.argv[1], prompt, clip_id)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/13_voice_zeroshot.py" >/dev/null <<'PY'
"""IndexTTS-2 zero-shot voice cloning + emotion + duration control.
Use for varied narration tones without training (vs GPT-SoVITS = fine-tuned).

Emotions (8-vector): happy, sad, angry, fear, disgust, surprise, neutral, calm
Each 0.0-1.0. Pass as comma-separated floats, e.g. "0.0,0.0,0.0,0.0,0.0,0.0,0.7,0.3"
"""
import sys, json, random, shutil, tomli
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config
from lib.comfy_client import ComfyClient

EMO_LABELS = ["happy","sad","angry","fear","disgust","surprise","neutral","calm"]
DEFAULT_EMO = "0,0,0,0,0,0,0.7,0.3"  # mostly neutral with calm

def main(slug: str, ref_wav: str, ref_text: str = "", emotion: str = DEFAULT_EMO,
         duration_seconds: float = 0.0):
    cfg = config.load()
    pdir = config.project_dir(slug)
    shots = tomli.loads((pdir / "shots.toml").read_text())["shots"]
    out_dir = pdir / "04_audio"
    out_dir.mkdir(exist_ok=True)
    wf_path = Path(cfg["paths"]["workflows"]) / cfg["workflows"]["indextts2"]
    if not wf_path.exists():
        print(f"[err] workflow missing: {wf_path}")
        return
    raw_template = wf_path.read_text()
    client = ComfyClient(cfg["hosts"]["comfyui"])
    for s in shots:
        text = s.get("narration", "").strip()
        if not text:
            continue
        target = out_dir / f"shot_{s['id']}.wav"
        seed = random.randint(1, 2**31 - 1)
        raw = (raw_template
               .replace("__REF_WAV__", ref_wav)
               .replace("__REF_TEXT__", ref_text)
               .replace("__TEXT__", text)
               .replace("__EMOTION__", emotion)
               .replace("__DURATION__", str(duration_seconds))
               .replace("__SEED__", str(seed)))
        print(f"[indextts2] shot {s['id']}: {text[:50]}...")
        pid = client.queue(json.loads(raw))
        history = client.wait(pid, timeout=300)
        outs = client.collect_outputs(history, str(out_dir))
        audio = [o for o in outs if o.endswith((".wav", ".mp3", ".flac"))]
        if audio:
            shutil.move(audio[-1], target)
            print(f"   -> {target}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: 13_voice_zeroshot.py <slug> <ref_wav> [ref_text] [emotion=8_floats] [duration]")
        sys.exit(1)
    ref_text = sys.argv[3] if len(sys.argv) > 3 else ""
    emo      = sys.argv[4] if len(sys.argv) > 4 else DEFAULT_EMO
    dur      = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
    main(sys.argv[1], sys.argv[2], ref_text, emo, dur)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/12_lipsync.py" >/dev/null <<'PY'
"""LTX 2.3 Lip-Sync: talking head video with synchronized lips from voice.
Requires: LTX 2.3 + LTX Lip-Sync LoRA installed (INSTALL_LTX=1).
Inputs: reference image, narration audio file, transcript.
Output: talking-head clip in projects/<slug>/07_lipsync/
"""
import sys, json, random, shutil
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config
from lib.comfy_client import ComfyClient

def main(slug: str, ref_image: str, audio: str, transcript: str, seconds: int = 10):
    cfg = config.load()
    pdir = config.project_dir(slug)
    out_dir = pdir / "07_lipsync"
    out_dir.mkdir(exist_ok=True)
    wf_path = Path(cfg["paths"]["workflows"]) / cfg["workflows"]["ltx_lipsync"]
    if not wf_path.exists():
        print(f"[err] workflow missing: {wf_path}")
        print("      after INSTALL_LTX=1 setup, build lipsync workflow in ComfyUI UI")
        return
    seed = random.randint(1, 2**31 - 1)
    raw = (wf_path.read_text()
           .replace("__REF_IMAGE__", ref_image)
           .replace("__AUDIO__", audio)
           .replace("__TRANSCRIPT__", transcript)   # appended to prompt for sync
           .replace("__SEED__", str(seed))
           .replace("__SECONDS__", str(seconds)))
    client = ComfyClient(cfg["hosts"]["comfyui"])
    pid = client.queue(json.loads(raw))
    history = client.wait(pid, timeout=2400)
    outs = client.collect_outputs(history, str(out_dir))
    videos = [o for o in outs if o.endswith((".mp4", ".webm"))]
    if videos:
        target = out_dir / f"talking_{seed}.mp4"
        shutil.move(videos[-1], target)
        print(f"[ok] {target}")

if __name__ == "__main__":
    if len(sys.argv) < 5:
        print("usage: 12_lipsync.py <slug> <ref_image> <audio_wav> <transcript> [seconds]")
        sys.exit(1)
    secs = int(sys.argv[5]) if len(sys.argv) > 5 else 10
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], secs)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/10_music.py" >/dev/null <<'PY'
"""Generate background music via ACE-Step 1.5 (or MusicGen for short beds).
Output: projects/<slug>/05_music/track.wav
"""
import sys, json, random, shutil
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config
from lib.comfy_client import ComfyClient

def main(slug: str, prompt: str, seconds: int = 60, model: str = "musicgen"):
    cfg = config.load()
    pdir = config.project_dir(slug)
    out_dir = pdir / "05_music"
    out_dir.mkdir(exist_ok=True)
    # default = musicgen (beats focused). use 'ace' for full-song style.
    wf_key = "music_musicgen" if model in ("musicgen", "mg", "beat") else "music_ace"
    wf_path = Path(cfg["paths"]["workflows"]) / cfg["workflows"][wf_key]
    if not wf_path.exists():
        print(f"[err] workflow missing: {wf_path}")
        print("      export from ComfyUI UI (API Format)")
        return
    raw = wf_path.read_text()
    seed = random.randint(1, 2**31 - 1)
    raw = (raw
           .replace("__PROMPT__", prompt)
           .replace("__SEED__", str(seed))
           .replace("__SECONDS__", str(seconds))
           .replace("__DURATION__", str(seconds)))
    client = ComfyClient(cfg["hosts"]["comfyui"])
    pid = client.queue(json.loads(raw))
    history = client.wait(pid, timeout=1800)
    outs = client.collect_outputs(history, str(out_dir))
    audio = [o for o in outs if o.endswith((".wav", ".mp3", ".flac", ".ogg"))]
    if audio:
        target = out_dir / "track.wav"
        shutil.move(audio[-1], target)
        print(f"[ok] {target}")
    else:
        print(f"[warn] no audio output: {outs}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: 10_music.py <slug> <prompt> [seconds=60] [musicgen|ace]")
        sys.exit(1)
    secs = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    model = sys.argv[4] if len(sys.argv) > 4 else "musicgen"
    main(sys.argv[1], sys.argv[2], secs, model)
PY

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/pipeline/stages/07_mux.py" >/dev/null <<'PY'
"""Concat clips, mix narration + background music, normalize loudness."""
import sys, subprocess
from pathlib import Path
sys.path.insert(0, "/opt/videogen/pipeline")
from lib import config

def main(slug: str):
    cfg  = config.load()
    pdir = config.project_dir(slug)
    src_dir = pdir / "03_upscaled"
    if not src_dir.exists():
        src_dir = pdir / "02_interpolated"
    if not src_dir.exists():
        src_dir = pdir / "01_clips"
    narr_dir = pdir / "04_audio"
    music_track = pdir / "05_music" / "track.wav"

    clips = sorted(src_dir.glob("shot_*.mp4"))
    if not clips:
        raise SystemExit(f"no clips in {src_dir}")

    # 1) concat video
    list_file = pdir / "_concat.txt"
    list_file.write_text("".join(f"file '{c}'\n" for c in clips))
    video_concat = pdir / "_video.mp4"
    subprocess.run([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(list_file),
        "-c", "copy", str(video_concat),
    ], check=True)

    # 2) concat narration if any
    narr_concat = None
    if narr_dir.exists():
        narr_clips = sorted(narr_dir.glob("shot_*.wav"))
        if narr_clips:
            alist = pdir / "_alist.txt"
            alist.write_text("".join(f"file '{a}'\n" for a in narr_clips))
            narr_concat = pdir / "_narr.wav"
            subprocess.run([
                "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(alist),
                "-c", "copy", str(narr_concat),
            ], check=True)

    # 3) build final audio mix
    final = pdir / "final.mp4"
    if narr_concat and music_track.exists():
        # narration over background music: duck music -16dB, normalize to -14 LUFS
        subprocess.run([
            "ffmpeg", "-y",
            "-i", str(video_concat), "-i", str(narr_concat), "-i", str(music_track),
            "-filter_complex",
            "[2:a]volume=0.18[bgm];[1:a][bgm]amix=inputs=2:duration=first:dropout_transition=2[aout];"
            "[aout]loudnorm=I=-14:LRA=11:TP=-1.5[final]",
            "-map", "0:v", "-map", "[final]",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
            "-shortest", str(final),
        ], check=True)
    elif narr_concat:
        subprocess.run([
            "ffmpeg", "-y", "-i", str(video_concat), "-i", str(narr_concat),
            "-c:v", "copy", "-af", "loudnorm=I=-14:LRA=11:TP=-1.5",
            "-c:a", "aac", "-b:a", "192k", "-shortest", str(final),
        ], check=True)
    elif music_track.exists():
        subprocess.run([
            "ffmpeg", "-y", "-i", str(video_concat), "-i", str(music_track),
            "-c:v", "copy", "-af", "loudnorm=I=-14:LRA=11:TP=-1.5",
            "-c:a", "aac", "-b:a", "192k", "-shortest", str(final),
        ], check=True)
    else:
        subprocess.run(["cp", str(video_concat), str(final)], check=True)

    for f in [list_file, video_concat, pdir / "_alist.txt", narr_concat]:
        if f and Path(f).exists():
            Path(f).unlink()

    print(f"[ok] {final}")

if __name__ == "__main__":
    main(sys.argv[1])
PY

# ---- Justfile ----
log "Justfile"
sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/justfile" >/dev/null <<'JUST'
# /opt/videogen Justfile — daily commands

set shell := ["bash", "-cu"]

py := "/opt/videogen/.venv/bin/python"
stages := "/opt/videogen/pipeline/stages"

default:
    @just --list

# scaffold a new project
new slug:
    mkdir -p /opt/videogen/projects/{{slug}}
    @echo "ok -> /opt/videogen/projects/{{slug}}"

# draft script with Qwen (Ollama)
script slug topic seconds="90":
    {{py}} {{stages}}/01_script.py {{slug}} "{{topic}}" {{seconds}}

# break script into shotlist
shots slug clip_secs="5":
    {{py}} {{stages}}/02_storyboard.py {{slug}} {{clip_secs}}

# render all clips (or a single shot id)
render slug shot_id="":
    {{py}} {{stages}}/03_render.py {{slug}} {{shot_id}}

# RIFE-style interpolation (uses ffmpeg minterpolate)
interpolate slug:
    {{py}} {{stages}}/04_interpolate.py {{slug}}

# upscale to 1080p
upscale slug w="1920" h="1080":
    {{py}} {{stages}}/05_upscale.py {{slug}} {{w}} {{h}}

# narration via GPT-SoVITS (needs api_v2 running on :9880)
voice slug ref_wav ref_text:
    {{py}} {{stages}}/06_voice.py {{slug}} "{{ref_wav}}" "{{ref_text}}"

# concat + mux + loudnorm
mux slug:
    {{py}} {{stages}}/07_mux.py {{slug}}

# generate YouTube thumbnail (1920x1080) via Flux Krea
thumbnail slug prompt model="flux":
    {{py}} {{stages}}/08_thumbnail.py {{slug}} "{{prompt}}" {{model}}

# generate one ref still per shot (use as I2V input for cleaner video)
storyboard-imgs slug model="flux":
    {{py}} {{stages}}/09_storyboard_imgs.py {{slug}} {{model}}

# generate background beats via MusicGen (default) or ACE-Step (full-song style)
music slug prompt seconds="60" model="musicgen":
    {{py}} {{stages}}/10_music.py {{slug}} "{{prompt}}" {{seconds}} {{model}}

# add ambient/SFX audio to existing video clips via Hunyuan-Foley
foley slug prompt="ambient natural sound" shot_id="":
    {{py}} {{stages}}/11_foley.py {{slug}} "{{prompt}}" {{shot_id}}

# talking-head lip-sync (LTX 2.3 + Lip-Sync LoRA, requires INSTALL_LTX=1)
lipsync slug ref_image audio transcript seconds="10":
    {{py}} {{stages}}/12_lipsync.py {{slug}} {{ref_image}} {{audio}} "{{transcript}}" {{seconds}}

# zero-shot narration via IndexTTS-2 (no training; emotion + duration control)
# emotion: 8 floats CSV (happy,sad,angry,fear,disgust,surprise,neutral,calm)
voice-zeroshot slug ref_wav ref_text="" emotion="0,0,0,0,0,0,0.7,0.3" duration="0":
    {{py}} {{stages}}/13_voice_zeroshot.py {{slug}} {{ref_wav}} "{{ref_text}}" "{{emotion}}" {{duration}}

# --- LoRA management (Civitai) ---

# show all category presets
lora-categories:
    {{py}} {{stages}}/20_lora.py categories

# search top LoRAs in a category (e.g. video/motion-wan22)
lora-search category limit="20":
    {{py}} {{stages}}/20_lora.py search {{category}} {{limit}}

# install a specific LoRA by Civitai URL or model id
lora-install url category:
    {{py}} {{stages}}/20_lora.py install {{url}} {{category}}

# install top N commercial-OK LoRAs for a category
lora-install-top category n="5":
    {{py}} {{stages}}/20_lora.py install-top {{category}} {{n}}

# list installed LoRAs (with trigger words)
lora-list:
    {{py}} {{stages}}/20_lora.py list

# full pipeline (no voice)
all slug:
    just render {{slug}}
    just interpolate {{slug}}
    just upscale {{slug}}
    just mux {{slug}}

# full pipeline w/ image-first workflow (better video quality)
all-img slug:
    just storyboard-imgs {{slug}}
    just render {{slug}}
    just interpolate {{slug}}
    just upscale {{slug}}
    just mux {{slug}}

# stop other GPU services for full VRAM
stop:
    /opt/videogen/scripts/stop_all.sh

# restart other GPU services
start:
    /opt/videogen/scripts/start_all.sh

# show GPU
gpu:
    rocm-smi || true

# tail comfyui logs
logs:
    journalctl -u comfyui -f
JUST

# ---- helper scripts ----
log "Helper scripts"
sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/scripts/stop_all.sh" >/dev/null <<'BASH'
#!/usr/bin/env bash
# free GPU VRAM for big renders
for s in ollama gpt-sovits whisper; do
    if systemctl is-active --quiet "$s"; then
        echo "stopping $s"
        sudo systemctl stop "$s"
    fi
done
sleep 2
rocm-smi || true
BASH
sudo -u "${SERVICE_USER}" chmod +x "${INSTALL_DIR}/scripts/stop_all.sh"

sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/scripts/start_all.sh" >/dev/null <<'BASH'
#!/usr/bin/env bash
for s in ollama whisper gpt-sovits; do
    if systemctl list-unit-files | grep -q "^${s}\.service"; then
        echo "starting $s"
        sudo systemctl start "$s" || true
    fi
done
BASH
sudo -u "${SERVICE_USER}" chmod +x "${INSTALL_DIR}/scripts/start_all.sh"

# allow videogen user to control these services without password
log "Sudoers rule for service control"
cat >/etc/sudoers.d/videogen-services <<EOF
${SERVICE_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl stop ollama, /usr/bin/systemctl start ollama, /usr/bin/systemctl stop whisper, /usr/bin/systemctl start whisper, /usr/bin/systemctl stop gpt-sovits, /usr/bin/systemctl start gpt-sovits, /usr/bin/systemctl stop comfyui, /usr/bin/systemctl start comfyui
EOF
chmod 440 /etc/sudoers.d/videogen-services

# ---- workflow placeholders ----
log "Workflow placeholders (export real ones from ComfyUI UI)"
for f in \
    ltx23_t2v.json ltx23_i2v.json ltx23_lipsync.json \
    wan22_t2v.json wan22_i2v.json wan22_flf2v.json wan22_5b_turbo.json \
    flux2_t2i.json flux_krea_t2i.json qwen_image_t2i.json sdxl_t2i.json \
    music_ace_step.json music_musicgen.json hunyuan_foley.json indextts2.json; do
    if [[ ! -f "${INSTALL_DIR}/workflows/${f}" ]]; then
        sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/workflows/${f}" >/dev/null <<EOF
{
  "_README": "Replace this file with a real ComfyUI workflow JSON (Save (API Format)).",
  "_REQUIRED_PLACEHOLDERS": [
    "__PROMPT__", "__SEED__", "__FRAMES__",
    "__WIDTH__", "__HEIGHT__", "__FPS__",
    "__FIRST_FRAME__ (i2v/flf2v only)", "__LAST_FRAME__ (flf2v only)"
  ]
}
EOF
    fi
done

# ---- README in install dir ----
sudo -u "${SERVICE_USER}" tee "${INSTALL_DIR}/HOWTO.txt" >/dev/null <<'EOF'
VIDEOGEN PIPELINE
=================

Run as: sudo -iu videogen
Then:   cd /opt/videogen

Daily commands:
  just                          # list commands
  just new myvid
  just script myvid "topic"     # Qwen drafts via Ollama
  just shots myvid              # split into shotlist
  just render myvid             # ComfyUI batch render (FLF2V chain)
  just render myvid 03          # regen one shot
  just interpolate myvid
  just upscale myvid
  just voice myvid /path/ref.wav "ref transcript"
  just mux myvid                # final.mp4
  just stop                     # free VRAM
  just start                    # restart services

ONE-TIME SETUP (after install):
  1. Open ComfyUI: http://SERVER:8188
  2. Build a Wan 2.2 T2V workflow (load high+low noise GGUF, encoder, VAE, sampler)
  3. Replace text fields with placeholders __PROMPT__, __SEED__ etc.
  4. Top-right: Workflow -> Save (API Format) -> save to /opt/videogen/workflows/wan22_t2v.json
  5. Repeat for wan22_i2v.json (FLF2V/I2V workflow with __FIRST_FRAME__)

PROJECT STRUCTURE:
  projects/<slug>/
    script.md
    shots.toml
    01_clips/        T2V/I2V outputs
    02_interpolated/ 16->32fps
    03_upscaled/     -> 1080p
    04_audio/        per-shot narration
    final.mp4
EOF

# ---- profile entry for videogen user ----
sudo -u "${SERVICE_USER}" tee -a "/var/lib/${SERVICE_USER}/.bashrc" >/dev/null <<'EOF'

# videogen pipeline
export PATH="/opt/videogen/.venv/bin:$PATH"

# Civitai API key (paste yours here for early-access on Bronze+ tier).
# Get from: https://civitai.com/user/account -> API Keys
# Free tier works without this; paid tier benefits from it.
# export CIVITAI_API_KEY=""

cd /opt/videogen 2>/dev/null || true
EOF

# also create a placeholder secrets file user can populate
sudo -u "${SERVICE_USER}" tee "/var/lib/${SERVICE_USER}/.civitai_env" >/dev/null <<'EOF'
# Source this file or copy into ~/.bashrc to enable Civitai paid features.
# Get key: https://civitai.com/user/account -> API Keys
# CIVITAI_API_KEY=
EOF
sudo chmod 600 "/var/lib/${SERVICE_USER}/.civitai_env"

cat <<EOF

============================================================
 Videogen pipeline installed at ${INSTALL_DIR}

 Switch user:    sudo -iu ${SERVICE_USER}
 List commands:  just
 Read howto:     cat /opt/videogen/HOWTO.txt

 Required next step:
   Build real ComfyUI workflows in the UI, save (API Format) to:
     /opt/videogen/workflows/wan22_t2v.json
     /opt/videogen/workflows/wan22_i2v.json
   Replace prompt/seed/frame fields with __PROMPT__, __SEED__, etc.
============================================================
EOF
