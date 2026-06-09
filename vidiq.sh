#!/usr/bin/env bash
# Thin CLI wrapper for the vidIQ MCP server (https://mcp.vidiq.com/mcp).
# Reads VIDIQ_MCP_KEY from .env (same dir). Bearer auth, streamable-HTTP MCP.
#
# Usage:
#   ./vidiq.sh <tool_name> '<json-args>'
#   ./vidiq.sh vidiq_balance '{}'
#   ./vidiq.sh vidiq_youtube_search '{"query":"best local LLM 16GB VRAM 2026"}'
#   ./vidiq.sh vidiq_video_transcript '{"video_id":"67Jl8CYonIY"}'
#   ./vidiq.sh --list                       # list available tools
#
# Native MCP access is also configured in .mcp.json (restart Claude to load).

set -euo pipefail

ENDPOINT="https://mcp.vidiq.com/mcp"
HERE="$(dirname "$(readlink -f "$0")")"
[[ -f "${HERE}/.env" ]] && { set -a; . "${HERE}/.env"; set +a; }
: "${VIDIQ_MCP_KEY:?set VIDIQ_MCP_KEY (in .env or env)}"

mcp() {
    curl -s -X POST "${ENDPOINT}" \
        -H "Authorization: Bearer ${VIDIQ_MCP_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d "$1" | sed 's/^data: //' | grep '"result"\|"error"' | tail -1
}

if [[ "${1:-}" == "--list" ]]; then
    mcp '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
        | jq -r '.result.tools[]? | "\(.name)\t\(.description)"'
    exit 0
fi

TOOL="${1:?tool name required (or --list)}"
ARGS="${2:-{\}}"
REQ=$(jq -n --arg t "$TOOL" --argjson a "$ARGS" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$t,arguments:$a}}')
mcp "$REQ" | jq -r '.result.content[]?.text // .result // .error'
