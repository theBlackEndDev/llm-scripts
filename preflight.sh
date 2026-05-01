#!/usr/bin/env bash
# Preflight check — run BEFORE any install scripts.
# Verifies ROCm, Vulkan, disk, RAM, network, no port conflicts.
# Reports green/yellow/red per check. Exits 1 on red.

set -uo pipefail

readonly REQ_DISK_GB=120
readonly REQ_RAM_GB=15
readonly PORTS_NEEDED=(8188 9874 9000 11434)

GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
DIM='\033[2m'
NC='\033[0m'

ok()   { printf "${GREEN}[ ok ]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; FAIL_WARN=1; }
err()  { printf "${RED}[FAIL]${NC} %s\n" "$*"; FAIL_HARD=1; }
info() { printf "${DIM}       %s${NC}\n" "$*"; }
hdr()  { printf "\n\033[1m== %s ==\033[0m\n" "$*"; }

FAIL_HARD=0
FAIL_WARN=0

# ---------- ROCm ----------
hdr "ROCm"

detect_rocm_version() {
    local v=""
    if command -v rocminfo >/dev/null 2>&1; then
        v=$(rocminfo 2>/dev/null | awk '/^Runtime Version:|^ROCk module version|RuntimeVersion:/ {print $NF}' | head -1)
    fi
    if [[ -z "$v" && -f /opt/rocm/.info/version ]]; then
        v=$(< /opt/rocm/.info/version)
    fi
    if [[ -z "$v" && -f /opt/rocm/.info/version-dev ]]; then
        v=$(< /opt/rocm/.info/version-dev)
    fi
    if [[ -z "$v" ]] && command -v dpkg >/dev/null 2>&1; then
        v=$(dpkg -l 2>/dev/null | awk '$2 ~ /^rocm-core$/ {print $3}' | head -1 | cut -d'-' -f1 | cut -d'~' -f1)
    fi
    if [[ -z "$v" ]]; then
        v=$(ls -d /opt/rocm-*/ 2>/dev/null | head -1 | sed -E 's|.*/rocm-([0-9.]+)/?|\1|')
    fi
    echo "$v"
}

ROCM_VER="$(detect_rocm_version)"
if [[ -z "$ROCM_VER" ]]; then
    err "ROCm not detected. install-comfyui.sh / install-gpt-sovits.sh need ROCm."
    info "Install via AMD: https://rocm.docs.amd.com/projects/install-on-linux/en/latest/"
else
    ok "ROCm version: $ROCM_VER"
    ROCM_MM=$(echo "$ROCM_VER" | cut -d. -f1-2)
    case "$ROCM_MM" in
        5.*)         err "ROCm 5.x too old. Upgrade to 6.2+." ;;
        6.0|6.1)     warn "ROCm $ROCM_MM works but PyTorch wheel may be stale. Recommend 6.2+." ;;
        6.2|6.3|6.4) ok "ROCm $ROCM_MM matches stable PyTorch wheel index" ;;
        7.0|7.1|7.2) ok "ROCm $ROCM_MM matches stable PyTorch wheel index (perf gains vs 6.x)" ;;
        7.3|7.4)     warn "ROCm $ROCM_MM newer than PyTorch stable wheel. Will fall back to rocm7.2 wheel." ;;
        *)           warn "ROCm $ROCM_MM unrecognized. Will try rocm6.2 wheel as fallback." ;;
    esac
fi

# ---------- AMD GPU + devices ----------
hdr "GPU + devices"
if [[ -e /dev/kfd ]] && ls /dev/dri/renderD* >/dev/null 2>&1; then
    ok "/dev/kfd + /dev/dri/renderD* present"
else
    err "Missing /dev/kfd or /dev/dri/renderD*. AMDGPU kernel module loaded?"
fi

if command -v rocm-smi >/dev/null 2>&1; then
    GPU_NAME=$(rocm-smi --showproductname 2>/dev/null | awk -F: '/Card series/ {print $2}' | head -1 | xargs)
    [[ -n "$GPU_NAME" ]] && ok "GPU detected: $GPU_NAME" || warn "rocm-smi present but GPU name not parsed"
    if rocm-smi --showproductname 2>/dev/null | grep -qi "6900\|6800\|6700\|6600"; then
        info "RDNA2 detected → HSA_OVERRIDE_GFX_VERSION=10.3.0 will be set in service units"
    fi
else
    warn "rocm-smi missing. Install rocm-smi-lib or full ROCm dev tools."
fi

# ---------- Vulkan (whisper.cpp path) ----------
hdr "Vulkan"
if command -v vulkaninfo >/dev/null 2>&1; then
    if vulkaninfo --summary 2>/dev/null | grep -qiE "radeon|amd|6900|rdna"; then
        ok "Vulkan sees AMD GPU"
    else
        warn "Vulkan present but no AMD device matched. whisper.cpp Vulkan may not pick GPU."
    fi
else
    warn "vulkaninfo missing. Install: sudo apt install vulkan-tools mesa-vulkan-drivers"
fi

# ---------- Disk ----------
hdr "Disk"
for d in /opt /var /home; do
    avail_gb=$(df -BG --output=avail "$d" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [[ -z "$avail_gb" ]]; then
        warn "$d not present or unreadable"
        continue
    fi
    if [[ "$avail_gb" -ge "$REQ_DISK_GB" ]]; then
        ok "$d : ${avail_gb}GB free (need ${REQ_DISK_GB}GB)"
    elif [[ "$avail_gb" -ge $((REQ_DISK_GB / 2)) ]]; then
        warn "$d : ${avail_gb}GB free (recommend ${REQ_DISK_GB}GB; tight)"
    else
        err "$d : ${avail_gb}GB free (need ${REQ_DISK_GB}GB)"
    fi
done

# ---------- RAM ----------
hdr "RAM"
RAM_GB=$(free -g | awk '/^Mem:/ {print $2}')
if [[ "$RAM_GB" -ge 60 ]]; then
    ok "${RAM_GB}GB RAM (LTX 2.3 territory — set INSTALL_LTX=1 on comfyui install)"
elif [[ "$RAM_GB" -ge 30 ]]; then
    ok "${RAM_GB}GB RAM (Wan 2.2 Q5/Q6 comfortable; LTX 2.3 not yet)"
elif [[ "$RAM_GB" -ge "$REQ_RAM_GB" ]]; then
    warn "${RAM_GB}GB RAM (works for Wan 2.2 Q4_K_M; one model at a time; tight)"
else
    err "${RAM_GB}GB RAM (need ≥${REQ_RAM_GB}GB)"
fi

# ---------- Network ----------
hdr "Network"
for url in https://huggingface.co https://github.com https://download.pytorch.org; do
    if curl -fsS --max-time 8 -I "$url" >/dev/null 2>&1; then
        ok "$url reachable"
    else
        err "$url unreachable"
    fi
done

# ---------- Ports ----------
hdr "Port conflicts"
for p in "${PORTS_NEEDED[@]}"; do
    in_use=$(ss -ltn 2>/dev/null | awk -v p=":$p" '$4 ~ p {print $4}' | head -1)
    if [[ -z "$in_use" ]]; then
        ok "port $p free"
    else
        # Check if it's our own service
        owner=""
        case "$p" in
            9000) owner="whisper (nginx)" ;;
            9001) owner="whisper-server (internal)" ;;
            8188) owner="comfyui" ;;
            9874) owner="gpt-sovits" ;;
            11434) owner="ollama" ;;
        esac
        if [[ -n "$owner" ]]; then
            info "port $p occupied (expected: $owner)"
        else
            warn "port $p occupied by unknown service: $in_use"
        fi
    fi
done

# ---------- Existing services ----------
hdr "Services"
for s in whisper ollama comfyui gpt-sovits; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"; then
        state=$(systemctl is-active "$s" 2>/dev/null || true)
        info "${s}.service exists: $state"
    fi
done

# ---------- Whisper sanity ----------
hdr "Existing whisper (if installed)"
if curl -fsS --max-time 4 http://127.0.0.1:9000/inference -X POST \
        -F file=@/opt/whisper.cpp/samples/jfk.wav 2>/dev/null | grep -q '"text"'; then
    ok "whisper.cpp endpoint responding on :9000"
else
    info "whisper not yet installed or not reachable (expected on first run)"
fi

# ---------- Summary ----------
echo
hdr "SUMMARY"
if [[ "$FAIL_HARD" -ne 0 ]]; then
    printf "${RED}FAIL${NC}: hard issues. Fix before running install scripts.\n"
    exit 1
elif [[ "$FAIL_WARN" -ne 0 ]]; then
    printf "${YELLOW}OK with warnings${NC}: install will proceed but review yellow lines.\n"
    exit 0
else
    printf "${GREEN}ALL CLEAR${NC}: ready to run install-*.sh\n"
fi

# Export detection for sourcing
echo
echo "Detected ROCm:    $ROCM_VER"
echo "RAM:              ${RAM_GB}GB"
[[ "$RAM_GB" -ge 60 ]] && echo "Recommend:        INSTALL_LTX=1 WAN_QUANT=Q6_K when running install-comfyui.sh"
