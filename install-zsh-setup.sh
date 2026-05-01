#!/usr/bin/env bash
# Replicate hus's Mac zsh setup on a fresh Linux box.
# Portable subset only — no Mac-specific paths (Solana, Antigravity, PAI, etc).
#
# Run as your interactive login user (NOT sudo). Will sudo apt install zsh.
#
#   bash install-zsh-setup.sh
#
# Idempotent: re-running upgrades pieces and rewrites ~/.zshrc from template.
# Existing ~/.zshrc is backed up to ~/.zshrc.bak.<timestamp> before overwrite.

set -euo pipefail

if [[ $EUID -eq 0 ]]; then
    echo "Run as your normal login user, not sudo."
    exit 1
fi

USER_HOME="${HOME}"
USER_NAME="$(id -un)"
ZSH_DIR="${USER_HOME}/.oh-my-zsh"
ZSH_CUSTOM_DIR="${ZSH_DIR}/custom"
SYNTAX_HL_DIR="${ZSH_CUSTOM_DIR}/plugins/zsh-syntax-highlighting"

log() { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# ---- system deps ----
log "System deps (sudo)"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    zsh git curl ca-certificates fonts-powerline

# ---- chsh ----
ZSH_BIN="$(command -v zsh)"
CURRENT_SHELL="$(getent passwd "${USER_NAME}" | cut -d: -f7)"
if [[ "${CURRENT_SHELL}" != "${ZSH_BIN}" ]]; then
    log "Setting login shell to ${ZSH_BIN} (sudo chsh)"
    sudo chsh -s "${ZSH_BIN}" "${USER_NAME}"
else
    log "Login shell already zsh"
fi

# ---- oh-my-zsh ----
if [[ ! -d "${ZSH_DIR}" ]]; then
    log "Installing oh-my-zsh"
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
else
    log "oh-my-zsh present, pulling latest"
    git -C "${ZSH_DIR}" pull --ff-only || warn "oh-my-zsh pull failed (non-fatal)"
fi

# ---- zsh-syntax-highlighting (as omz custom plugin) ----
if [[ ! -d "${SYNTAX_HL_DIR}" ]]; then
    log "Cloning zsh-syntax-highlighting"
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "${SYNTAX_HL_DIR}"
else
    log "Updating zsh-syntax-highlighting"
    git -C "${SYNTAX_HL_DIR}" pull --ff-only || warn "syntax-highlighting pull failed (non-fatal)"
fi

# ---- zsh-autosuggestions (bonus, not on Mac but useful on a server) ----
AUTOSUG_DIR="${ZSH_CUSTOM_DIR}/plugins/zsh-autosuggestions"
if [[ ! -d "${AUTOSUG_DIR}" ]]; then
    log "Cloning zsh-autosuggestions"
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git "${AUTOSUG_DIR}"
else
    git -C "${AUTOSUG_DIR}" pull --ff-only || warn "autosuggestions pull failed (non-fatal)"
fi

# ---- backup existing .zshrc ----
if [[ -f "${USER_HOME}/.zshrc" ]] && ! grep -q '# managed by install-zsh-setup.sh' "${USER_HOME}/.zshrc"; then
    BACKUP="${USER_HOME}/.zshrc.bak.$(date +%Y%m%d-%H%M%S)"
    log "Backing up existing .zshrc -> ${BACKUP}"
    cp "${USER_HOME}/.zshrc" "${BACKUP}"
fi

# ---- write .zshrc (portable subset of Mac config) ----
log "Writing ~/.zshrc"
cat >"${USER_HOME}/.zshrc" <<'ZSHRC'
# managed by install-zsh-setup.sh — Mac config minus machine-specific bits

export ZSH="$HOME/.oh-my-zsh"

ZSH_THEME="pygmalion"

HYPHEN_INSENSITIVE="true"

plugins=(git colorize github pip python zsh-syntax-highlighting zsh-autosuggestions)

source $ZSH/oh-my-zsh.sh

# ---- aliases ----
alias ...=../..
alias ....=../../..
alias .....=../../../..
alias ......=../../../../..
alias ll='ls -lash'
alias clean='rm -fr *lock* && rm -fr node_modules && yarn install && rm -fr node_modules && npm install'

# ---- nvm ----
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# ---- user bin (claude code launcher etc) ----
export PATH="$HOME/bin:$PATH"

# ---- local user-specific overrides (not tracked) ----
[ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
ZSHRC

# ---- nvm + Node 20 (skip if already installed by install-claude-code.sh) ----
if [[ ! -d "${USER_HOME}/.nvm" ]]; then
    log "Installing nvm"
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    export NVM_DIR="${USER_HOME}/.nvm"
    # shellcheck disable=SC1091
    source "${NVM_DIR}/nvm.sh"
    nvm install 20
    nvm alias default 20
else
    log "nvm present"
fi

cat <<EOF

============================================================
 zsh setup ready.

 Shell:   ${ZSH_BIN}
 Theme:   pygmalion
 Plugins: git colorize github pip python zsh-syntax-highlighting zsh-autosuggestions

 Custom local overrides go in:  ~/.zshrc.local  (sourced last, untracked)

 To use it now:
   exec zsh

 If chsh was applied, next ssh login will already be zsh.
============================================================
EOF
