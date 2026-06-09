#!/usr/bin/env bash
# Profile system — orchestrates services + Ollama models for specific workflows.
# Run: sudo ./install-profiles.sh
#
# Each profile is a small bash file in /etc/profiles/*.sh with:
#   PROFILE_DESC, START="svc1 svc2", STOP="svc3 svc4",
#   OLLAMA_MODEL=optional, OLLAMA_KEEP=optional,
#   EXPECTED_VRAM_GB=N, EXPECTED_RAM_GB=N
#
# Usage after install:
#   profile list
#   profile <name>
#   profile status
#   profile current

set -euo pipefail

readonly PROFILES_DIR="/etc/profiles"
readonly STATE_DIR="/var/lib/profile"
readonly BIN_PATH="/usr/local/bin/profile"

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

log() { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }

mkdir -p "${PROFILES_DIR}" "${STATE_DIR}"
chmod 755 "${PROFILES_DIR}" "${STATE_DIR}"

# ===== dispatcher =====
log "Writing dispatcher -> ${BIN_PATH}"
cat >"${BIN_PATH}" <<'DISPATCH'
#!/usr/bin/env bash
# profile <name> | status | list | current | edit <name>
set -euo pipefail

PROFILES_DIR="/etc/profiles"
STATE_DIR="/var/lib/profile"
CURRENT="${STATE_DIR}/current"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

list_profiles() {
    bold "Available profiles:"
    for f in "${PROFILES_DIR}"/*.sh; do
        [[ -f "$f" ]] || continue
        local name="$(basename "$f" .sh)"
        # shellcheck disable=SC1090
        ( source "$f"
          printf "  \033[1;36m%-16s\033[0m %s\n" "$name" "${PROFILE_DESC:-}"
        )
    done
}

show_status() {
    bold "Current profile: $(cat "${CURRENT}" 2>/dev/null || echo '<none>')"
    echo
    bold "Services:"
    for s in ollama whisper gpt-sovits comfyui llama-server; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"; then
            local state
            state=$(systemctl is-active "$s" 2>/dev/null || echo "unknown")
            printf "  %-16s %s\n" "$s" "$state"
        fi
    done
    echo
    bold "GPU:"
    if command -v rocm-smi >/dev/null 2>&1; then
        rocm-smi --showuse --showmemuse 2>/dev/null | grep -E "GPU\[|VRAM" | head -10 || true
    fi
    echo
    bold "RAM:"
    free -h | awk 'NR<=2 {print "  " $0}'
}

apply_profile() {
    local name="$1"
    local file="${PROFILES_DIR}/${name}.sh"
    [[ -f "$file" ]] || { echo "Profile not found: $name"; exit 1; }

    # shellcheck disable=SC1090
    source "$file"

    bold "Switching to: $name"
    [[ -n "${PROFILE_DESC:-}" ]] && dim "  $PROFILE_DESC"

    # stop
    for s in ${STOP:-}; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            echo "  stop  $s"
            sudo systemctl stop "$s" || true
        fi
    done

    sleep 1

    # llama-server overrides (write systemd drop-in before starting).
    # A profile may override model, expert-offload depth, and context.
    if [[ -n "${LLAMA_MODEL_OVERRIDE:-}" ]] && echo "${START:-}" | grep -qw "llama-server"; then
        echo "  llama-server model: ${LLAMA_MODEL_OVERRIDE}"
        sudo mkdir -p /etc/systemd/system/llama-server.service.d
        {
            echo "[Service]"
            echo "Environment=LLAMA_MODEL=${LLAMA_MODEL_OVERRIDE}"
            [[ -n "${LLAMA_NCPUMOE_OVERRIDE:-}" ]] && echo "Environment=LLAMA_NCPUMOE=${LLAMA_NCPUMOE_OVERRIDE}"
            [[ -n "${LLAMA_CTX_OVERRIDE:-}" ]]     && echo "Environment=LLAMA_CTX=${LLAMA_CTX_OVERRIDE}"
        } | sudo tee /etc/systemd/system/llama-server.service.d/profile.conf >/dev/null
        sudo systemctl daemon-reload
    elif echo "${START:-}" | grep -qw "llama-server"; then
        # clear override -> use unit default
        sudo rm -f /etc/systemd/system/llama-server.service.d/profile.conf
        sudo systemctl daemon-reload
    fi

    # start
    for s in ${START:-}; do
        if ! systemctl is-active --quiet "$s" 2>/dev/null; then
            echo "  start $s"
            sudo systemctl start "$s" || echo "    (failed, ignoring)"
        fi
    done

    # ollama preload
    if [[ -n "${OLLAMA_MODEL:-}" ]]; then
        echo "  ollama preload: $OLLAMA_MODEL (keep_alive=${OLLAMA_KEEP:-1h})"
        # wait for ollama API to come up
        for i in 1 2 3 4 5; do
            if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
                break
            fi
            sleep 2
        done
        curl -fsS http://127.0.0.1:11434/api/generate \
            -d "{\"model\":\"${OLLAMA_MODEL}\",\"prompt\":\"\",\"keep_alive\":\"${OLLAMA_KEEP:-1h}\"}" \
            >/dev/null 2>&1 || true
    fi

    echo "$name" | sudo tee "${CURRENT}" >/dev/null

    [[ -n "${EXPECTED_VRAM_GB:-}" ]] && dim "  expected VRAM: ~${EXPECTED_VRAM_GB} GB"
    [[ -n "${EXPECTED_RAM_GB:-}"  ]] && dim "  expected RAM:  ~${EXPECTED_RAM_GB} GB"

    bold "Done."
}

cmd="${1:-status}"
case "$cmd" in
    list|ls)         list_profiles ;;
    status|st)       show_status ;;
    current)         cat "${CURRENT}" 2>/dev/null || echo "<none>" ;;
    edit)            "${EDITOR:-vi}" "${PROFILES_DIR}/${2}.sh" ;;
    -h|--help|help)  echo "usage: profile [list|status|current|edit <name>|<name>]" ;;
    *)               apply_profile "$cmd" ;;
esac
DISPATCH
chmod 755 "${BIN_PATH}"

# ===== profile definitions =====
log "Writing profile definitions"

write_profile() {
    local name="$1"
    local body="$2"
    cat >"${PROFILES_DIR}/${name}.sh" <<EOF
${body}
EOF
    chmod 644 "${PROFILES_DIR}/${name}.sh"
}

write_profile "off" '
PROFILE_DESC="Idle: stop all GPU services"
START=""
STOP="ollama whisper gpt-sovits comfyui llama-server"
EXPECTED_VRAM_GB=0
EXPECTED_RAM_GB=2
'

write_profile "dev" '
PROFILE_DESC="Coding: whisper dictation + small coding LLM"
START="whisper ollama"
STOP="comfyui gpt-sovits llama-server"
OLLAMA_MODEL="qwen3.5:9b"   # bump to qwen3-coder:7b once pulled
OLLAMA_KEEP="2h"
EXPECTED_VRAM_GB=7
EXPECTED_RAM_GB=10
'

write_profile "dictate" '
PROFILE_DESC="Dictation + LLM punctuation cleanup"
START="whisper ollama"
STOP="comfyui gpt-sovits llama-server"
OLLAMA_MODEL="qwen3.5:9b"
OLLAMA_KEEP="1h"
EXPECTED_VRAM_GB=6
EXPECTED_RAM_GB=8
'

write_profile "assistant" '
PROFILE_DESC="Voice loop: whisper STT + LLM + GPT-SoVITS TTS"
START="whisper ollama gpt-sovits"
STOP="comfyui llama-server"
OLLAMA_MODEL="qwen3.5:9b"
OLLAMA_KEEP="1h"
EXPECTED_VRAM_GB=10
EXPECTED_RAM_GB=14
'

write_profile "chat-big" '
PROFILE_DESC="Heavy reasoning: GPT-OSS 20B Q4"
START="ollama"
STOP="comfyui gpt-sovits whisper llama-server"
OLLAMA_MODEL="gpt-oss:20b"
OLLAMA_KEEP="2h"
EXPECTED_VRAM_GB=12
EXPECTED_RAM_GB=18
'

write_profile "gemma4-26b" '
PROFILE_DESC="Gemma 4 26B Q4_K_M (vision, 256K context). Needs 32GB+ RAM."
START="ollama"
STOP="comfyui gpt-sovits whisper llama-server"
OLLAMA_MODEL="gemma4:26b"
OLLAMA_KEEP="2h"
EXPECTED_VRAM_GB=10
EXPECTED_RAM_GB=24
'

write_profile "gemma4-light" '
PROFILE_DESC="Gemma 4 e4b (small, fast, fits everywhere)"
START="whisper ollama"
STOP="comfyui gpt-sovits llama-server"
OLLAMA_MODEL="gemma4:e4b"
OLLAMA_KEEP="1h"
EXPECTED_VRAM_GB=5
EXPECTED_RAM_GB=8
'

write_profile "moe-fast" '
PROFILE_DESC="Fast daily MoE: Qwen3.5-35B-A3B IQ3_XXS (unit default, ~fits VRAM)"
START="llama-server"
STOP="ollama comfyui gpt-sovits whisper"
EXPECTED_VRAM_GB=14
EXPECTED_RAM_GB=10
'

write_profile "moe-instant" '
PROFILE_DESC="Instant coder: Gemma 4 12B Q8 (dense, fully in VRAM, zero offload)"
START="llama-server"
STOP="ollama comfyui gpt-sovits whisper"
LLAMA_MODEL_OVERRIDE="gemma-4-12b-it-Q8_0.gguf"
LLAMA_NCPUMOE_OVERRIDE="0"
LLAMA_CTX_OVERRIDE="32768"
EXPECTED_VRAM_GB=13
EXPECTED_RAM_GB=6
'

write_profile "moe-coder" '
PROFILE_DESC="Coding agent MoE: Qwen3-Coder-Next 38B IQ4_XS"
START="llama-server"
STOP="ollama comfyui gpt-sovits whisper"
LLAMA_MODEL_OVERRIDE="Qwen3-Coder-Next-UD-IQ4_XS.gguf"
LLAMA_NCPUMOE_OVERRIDE="10"
LLAMA_CTX_OVERRIDE="32768"
EXPECTED_VRAM_GB=15
EXPECTED_RAM_GB=14
'

write_profile "moe-quality" '
PROFILE_DESC="Top-tier MoE: Qwen3.5-122B-A10B IQ3_XXS (heavy CPU offload). Needs 64GB RAM."
START="llama-server"
STOP="ollama comfyui gpt-sovits whisper"
LLAMA_MODEL_OVERRIDE="Qwen3.5-122B-A10B-UD-IQ3_XXS.gguf"
LLAMA_NCPUMOE_OVERRIDE="40"
LLAMA_CTX_OVERRIDE="65536"
EXPECTED_VRAM_GB=15
EXPECTED_RAM_GB=52
'

write_profile "video-fast" '
PROFILE_DESC="Video gen: LTX 2.3 22B (fast iter, native audio). Needs 64GB+ RAM."
START="comfyui"
STOP="ollama whisper gpt-sovits llama-server"
EXPECTED_VRAM_GB=14
EXPECTED_RAM_GB=20
'

write_profile "video-quality" '
PROFILE_DESC="Video gen: Wan 2.2 14B (motion-realistic hero shots)"
START="comfyui"
STOP="ollama whisper gpt-sovits llama-server"
EXPECTED_VRAM_GB=13
EXPECTED_RAM_GB=12
'

write_profile "image" '
PROFILE_DESC="Image gen: Flux Krea / SDXL via ComfyUI"
START="comfyui"
STOP="ollama whisper gpt-sovits llama-server"
EXPECTED_VRAM_GB=12
EXPECTED_RAM_GB=10
'

write_profile "train-tts" '
PROFILE_DESC="GPT-SoVITS training run (voice fine-tune)"
START="gpt-sovits"
STOP="ollama whisper comfyui llama-server"
EXPECTED_VRAM_GB=14
EXPECTED_RAM_GB=20
'

write_profile "tts-bench" '
PROFILE_DESC="GPT-SoVITS inference + small LLM for prompts"
START="gpt-sovits ollama"
STOP="comfyui whisper llama-server"
OLLAMA_MODEL="qwen3.5:9b"
EXPECTED_VRAM_GB=8
EXPECTED_RAM_GB=14
'

write_profile "music" '
PROFILE_DESC="ACE-Step 1.5 / MusicGen via ComfyUI (low VRAM, can coexist)"
START="comfyui"
STOP="gpt-sovits llama-server"
EXPECTED_VRAM_GB=4
EXPECTED_RAM_GB=8
'

write_profile "music-light" '
PROFILE_DESC="Music gen + small LLM + whisper (full creative loop)"
START="comfyui ollama whisper"
STOP="gpt-sovits llama-server"
OLLAMA_MODEL="qwen3.5:9b"
EXPECTED_VRAM_GB=11
EXPECTED_RAM_GB=14
'

# ===== sudoers: allow profile dispatcher to control services for any user in 'profile-users' group =====
log "Sudoers rule for profile dispatcher"
groupadd -f profile-users
cat >/etc/sudoers.d/profile <<'EOF'
%profile-users ALL=(root) NOPASSWD: /usr/bin/systemctl start *, /usr/bin/systemctl stop *, /usr/bin/systemctl restart *, /usr/bin/tee /var/lib/profile/current
EOF
chmod 440 /etc/sudoers.d/profile

# ===== add common users to profile-users group =====
for u in hus videogen; do
    if id -u "$u" >/dev/null 2>&1; then
        usermod -aG profile-users "$u"
        log "added $u to profile-users group"
    fi
done

# ===== bash completion =====
log "Bash completion"
cat >/etc/bash_completion.d/profile <<'EOF'
_profile_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local cmds="list status current edit help"
    local profiles=$(ls /etc/profiles/*.sh 2>/dev/null | xargs -n1 basename | sed 's/\.sh$//')
    COMPREPLY=( $(compgen -W "${cmds} ${profiles}" -- "${cur}") )
}
complete -F _profile_complete profile
EOF

# ===== summary =====
cat <<EOF

============================================================
 Profile system installed.

 Dispatcher:    profile <command>
 Profiles dir:  ${PROFILES_DIR}/
 State:         ${STATE_DIR}/current

 Try:
   profile list
   profile dev
   profile status
   profile video-quality

 Custom profiles: drop a new .sh in ${PROFILES_DIR}/.
 Edit one:        sudo profile edit dev

 NOTE: switching profiles requires sudo for systemctl. The 'profile-users'
 group has been granted NOPASSWD systemctl start/stop. Open new shell so
 group membership takes effect:  exec su - \$USER
============================================================
EOF
