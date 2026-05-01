#!/usr/bin/env bash
set -euo pipefail

# Machine 2 local LLM bootstrap — Ubuntu Server 24.04 LTS
# Target:
# - Ubuntu Server 24.04 LTS
# - AMD RX 6900 XT
# - Ollama
# - llama.cpp (Vulkan build)
# - Tailscale for remote access
# - optional LAN access for Ollama
# - ROCm left as a manual follow-up, not day-one default

log() {
  printf '\n==> %s\n' "$1"
}

warn() {
  printf '\n[warn] %s\n' "$1"
}

if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run this script as your normal user, not root."
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required but not installed."
  exit 1
fi

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    warn "This script is intended for Ubuntu Server 24.04 LTS. Detected ID=${ID:-unknown}."
  fi
  if [[ "${VERSION_ID:-}" != "24.04" ]]; then
    warn "Expected Ubuntu 24.04. Detected VERSION_ID=${VERSION_ID:-unknown}."
  fi
fi

log "Updating apt metadata and upgrading packages"
sudo apt update
sudo apt full-upgrade -y

log "Installing server-oriented dependencies"
sudo apt install -y \
  build-essential \
  curl \
  wget \
  git \
  cmake \
  ninja-build \
  pkg-config \
  python3 \
  python3-pip \
  python3-venv \
  pciutils \
  mesa-vulkan-drivers \
  vulkan-tools \
  libvulkan-dev \
  clinfo \
  htop \
  tmux \
  unzip \
  zstd

log "Checking whether OpenSSH server is present"
if dpkg -s openssh-server >/dev/null 2>&1; then
  echo "openssh-server already installed"
else
  warn "openssh-server is not installed. Installing it now."
  sudo apt install -y openssh-server
fi

log "Installing Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable tailscaled || true
sudo systemctl start tailscaled || true

log "Checking GPU visibility"
lspci | grep -i -E 'amd|vga|display' || true
vulkaninfo --summary >/tmp/vulkan-summary.txt 2>/dev/null || true
if [[ -f /tmp/vulkan-summary.txt ]]; then
  echo "Saved Vulkan summary to /tmp/vulkan-summary.txt"
fi

log "Installing Ollama"
curl -fsSL https://ollama.com/install.sh | sh

log "Enabling and starting Ollama service"
sudo systemctl daemon-reload || true
sudo systemctl enable ollama || true
sudo systemctl restart ollama || true
sleep 2
systemctl --no-pager --full status ollama || true

log "Cloning llama.cpp if not already present"
if [[ ! -d "$HOME/llama.cpp" ]]; then
  git clone https://github.com/ggml-org/llama.cpp.git "$HOME/llama.cpp"
else
  echo "llama.cpp already exists at $HOME/llama.cpp"
fi

log "Building llama.cpp with Vulkan support"
cd "$HOME/llama.cpp"
git pull --ff-only || true
cmake -B build -S . -DGGML_VULKAN=ON
cmake --build build --config Release -j"$(nproc)"

log "Writing local helper files"
mkdir -p "$HOME/.config/local-llm"
cat > "$HOME/.config/local-llm/env.sh" <<'EOF'
# Source manually if desired:
#   source ~/.config/local-llm/env.sh
alias llm-gemma-e2b='ollama run gemma4:e2b'
alias llm-gemma-e4b='ollama run gemma4:e4b'
alias llm-qwen-coder='ollama run qwen2.5-coder:7b'
alias llm-ps='ollama ps'
alias llm-api='curl http://127.0.0.1:11434/api/tags'
EOF

cat > "$HOME/.config/local-llm/tailscale-setup.md" <<'EOF'
# Tailscale setup

After install, authenticate this server with your tailnet:

sudo tailscale up

Useful checks:
- tailscale status
- tailscale ip -4
- tailscale ip -6

If you want Ollama reachable over Tailscale, either:
- keep Ollama bound to localhost and use an SSH tunnel, or
- bind Ollama to 0.0.0.0:11434 and rely on firewall/Tailscale network boundaries

Do not expose Ollama directly to the public internet.
EOF

cat > "$HOME/.config/local-llm/ollama-lan-access.md" <<'EOF'
# Optional: expose Ollama on your LAN

Only do this if you want other devices on your network to reach this server.
Do not expose Ollama directly to the public internet.

## Create a systemd override
sudo systemctl edit ollama

Add:
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"

Then run:
sudo systemctl daemon-reload
sudo systemctl restart ollama
ss -ltnp | grep 11434
EOF

log "Next steps"
echo "1. Verify Ollama: ollama --version"
echo "2. Verify Ollama API locally: curl http://127.0.0.1:11434/api/tags"
echo "3. Pull models:"
echo "   ollama pull gemma4:e2b"
echo "   ollama pull gemma4:e4b"
echo "   ollama pull qwen2.5-coder:7b"
echo "4. Verify llama.cpp: ~/llama.cpp/build/bin/llama-cli --help"
echo "5. Join Tailscale: sudo tailscale up"
echo "6. Tailscale notes: ~/.config/local-llm/tailscale-setup.md"
echo "7. If you want LAN access, read: ~/.config/local-llm/ollama-lan-access.md"
echo "8. If performance or GPU usage looks wrong, verify Vulkan first."

cat <<'EOF'

Optional ROCm path (manual; verify current AMD docs first):
------------------------------------------------------------
ROCm package names and support details change over time.
Only add ROCm if Vulkan + Ollama + llama.cpp are not enough.
------------------------------------------------------------
EOF

log "Done"
