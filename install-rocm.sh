#!/usr/bin/env bash
# Install full AMD ROCm SDK on Ubuntu Server 24.04 for AMD RX 6900 XT (gfx1030).
# Required for ComfyUI + GPT-SoVITS PyTorch ROCm wheels.
# Coexists with Ollama's bundled ROCm runtime (different paths).
#
# Default: ROCm 6.4 (last with native RDNA2 support).
# Set ROCM_TRACK=7.2 for newer (needs HSA_OVERRIDE_GFX_VERSION=10.3.0; higher perf).

set -euo pipefail

readonly ROCM_TRACK="${ROCM_TRACK:-6.4}"

log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[X]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run with sudo."

# ---- preflight ----
log "Verifying Ubuntu 24.04"
. /etc/os-release
[[ "${VERSION_ID:-}" == "24.04" ]] || warn "Expected Ubuntu 24.04, got ${VERSION_ID:-unknown}"

if [[ -d /opt/rocm ]] || command -v rocminfo >/dev/null 2>&1; then
    EXIST_VER=$(cat /opt/rocm/.info/version 2>/dev/null || rocminfo 2>/dev/null | awk '/Runtime Version/ {print $NF}' | head -1)
    warn "ROCm already present (${EXIST_VER:-unknown}). Re-running may upgrade. Ctrl-C to abort, Enter to continue."
    read -r
fi

# ---- repo setup ----
log "Adding ROCm ${ROCM_TRACK} apt repo"
apt-get update
apt-get install -y --no-install-recommends \
    wget gnupg ca-certificates lsb-release software-properties-common

mkdir -p --mode=0755 /etc/apt/keyrings
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key \
    | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg > /dev/null

UBUNTU_CODENAME=$(lsb_release -cs)
cat >/etc/apt/sources.list.d/rocm.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/${ROCM_TRACK} ${UBUNTU_CODENAME} main
EOF

cat >/etc/apt/preferences.d/rocm-pin-600 <<EOF
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

# AMDGPU repo (kernel-mode + userspace bits)
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key \
    | gpg --dearmor | tee /etc/apt/keyrings/amdgpu.gpg > /dev/null
cat >/etc/apt/sources.list.d/amdgpu.list <<EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/amdgpu.gpg] https://repo.radeon.com/amdgpu/${ROCM_TRACK}/ubuntu ${UBUNTU_CODENAME} main
EOF

apt-get update

# ---- install ROCm runtime + dev libs (no DKMS — kernel module already on amdgpu) ----
log "Installing ROCm runtime + HIP SDK + math libs"
apt-get install -y --no-install-recommends \
    rocm-hip-runtime rocm-hip-sdk rocm-hip-libraries \
    rocm-libs rocminfo rocm-smi-lib hipcc \
    rocm-device-libs hipify-clang \
    miopen-hip rccl rocblas hipblas hipfft hiprand rocfft rocrand rocsparse hipsparse \
    rocsolver hipsolver hsa-rocr || \
    apt-get install -y --no-install-recommends rocm  # fallback meta

# ---- ldconfig + path ----
log "Configuring linker + PATH"
echo "/opt/rocm/lib" > /etc/ld.so.conf.d/rocm.conf
echo "/opt/rocm/lib64" >> /etc/ld.so.conf.d/rocm.conf
ldconfig

# Add ROCm to PATH for all users
cat >/etc/profile.d/rocm.sh <<'EOF'
export PATH="/opt/rocm/bin:${PATH}"
export ROCM_PATH="/opt/rocm"
# RDNA2 (6900XT = gfx1030) needs override for ROCm 7.x
export HSA_OVERRIDE_GFX_VERSION=10.3.0
EOF
chmod +x /etc/profile.d/rocm.sh

# ---- groups ----
log "Adding common users to render + video groups"
for u in $(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1}'); do
    usermod -aG render,video "$u" 2>/dev/null || true
done

# ---- verify ----
log "Verifying installation"
sleep 1
if /opt/rocm/bin/rocminfo >/dev/null 2>&1; then
    echo
    /opt/rocm/bin/rocminfo | grep -E "Name:|Marketing Name:|Compute Unit:|Runtime Version:" | head -20
    echo
fi

if command -v rocm-smi >/dev/null 2>&1; then
    rocm-smi --showproductname --showmeminfo vram 2>/dev/null || true
fi

VER=$(cat /opt/rocm/.info/version 2>/dev/null || echo "$ROCM_TRACK")

cat <<EOF

============================================================
 ROCm installed.

 Version:    ${VER}
 Path:       /opt/rocm
 Override:   HSA_OVERRIDE_GFX_VERSION=10.3.0 (in /etc/profile.d/rocm.sh)
 Groups:     all human users added to render + video

 NEXT (open new shell first so PATH + groups take effect):
   exec su - \$USER

   # Verify GPU visible to ROCm
   rocminfo | grep -E "Name:|Marketing Name:" | head -6
   rocm-smi

   # Now run preflight + comfyui install
   cd ~/llm-scripts
   ./preflight.sh
   sudo ./install-comfyui.sh

 NOTE: Ollama's bundled ROCm in /usr/share/ollama/lib/ remains untouched.
 Ollama keeps working as before. Coexists with this full SDK.
============================================================
EOF
