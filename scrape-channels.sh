#!/usr/bin/env bash
# Scrape recent videos from monitored YouTube channels.
# Pulls metadata + auto-captions, saves transcripts to docs/transcripts/<channel>/.
# Run weekly to keep up with rapidly evolving model space.
#
# Usage:
#   ./scrape-channels.sh                    # last 14 days, default channels
#   ./scrape-channels.sh 30                 # last 30 days
#   ./scrape-channels.sh 14 "@SomeChannel"  # custom channel

set -uo pipefail

DAYS="${1:-14}"
OUT_DIR="$(dirname "$(readlink -f "$0")")/docs/transcripts"
mkdir -p "${OUT_DIR}"

CHANNELS=(
    "@TensorAlchemist"     # 8GB VRAM workflows, model breakdowns
    "@sebastiankamph"      # ComfyUI fundamentals, comparisons
    "@OlivioSarikas"       # beginner-friendly, broad coverage
    "@LatentVision"        # technical deep dives
    "@Mickmumpitz"         # character consistency, production
    "@NerdyRodent"         # OSS focus
)
[[ $# -gt 1 ]] && CHANNELS=("${@:2}")

if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "yt-dlp missing. Install: brew install yt-dlp  (or pip install -U yt-dlp)"
    exit 1
fi

since_ts=$(date -v-${DAYS}d +%Y%m%d 2>/dev/null || date -d "-${DAYS} days" +%Y%m%d)

for ch in "${CHANNELS[@]}"; do
    safe="${ch#@}"
    ch_dir="${OUT_DIR}/${safe}"
    mkdir -p "${ch_dir}"
    echo
    echo "=== ${ch} (last ${DAYS} days) ==="

    # list videos with metadata
    yt-dlp --flat-playlist --print "%(id)s|%(title)s|%(duration_string)s|%(upload_date)s" \
        "https://www.youtube.com/${ch}/videos" 2>/dev/null \
        | head -30 \
        | while IFS='|' read -r vid title dur upload; do
            [[ -z "$vid" ]] && continue
            # filter by date if available
            if [[ -n "$upload" && "$upload" != "NA" && "$upload" < "$since_ts" ]]; then
                continue
            fi
            safe_title=$(echo "$title" | tr '/' '_' | tr -dc 'A-Za-z0-9 _-' | cut -c1-60)
            out_md="${ch_dir}/${vid}-${safe_title}.md"
            [[ -f "$out_md" ]] && { echo "  [skip] $title"; continue; }

            tmp_ttml="/tmp/scrape_${vid}.en.ttml"
            yt-dlp --skip-download --write-auto-subs --sub-langs en --sub-format ttml \
                --extractor-args "youtube:player_client=ios,web_safari" \
                -o "/tmp/scrape_${vid}" \
                "https://www.youtube.com/watch?v=${vid}" >/dev/null 2>&1 || true

            if [[ -f "$tmp_ttml" ]]; then
                python3 - "$tmp_ttml" "$out_md" "$title" "$ch" "$upload" "$dur" "$vid" <<'PY'
import re, html, sys
ttml, dst, title, channel, upload, dur, vid = sys.argv[1:]
raw = open(ttml).read()
parts = re.findall(r'<p[^>]*>(.*?)</p>', raw, re.DOTALL)
clean = []
for p in parts:
    p = re.sub(r'<[^>]+>', '', p)
    p = html.unescape(p)
    p = re.sub(r'\s+', ' ', p).strip()
    if p:
        clean.append(p)
text = re.sub(r'\s+', ' ', ' '.join(clean))
with open(dst, "w") as f:
    f.write(f"# {title}\n\n")
    f.write(f"- channel: {channel}\n")
    f.write(f"- video:   https://www.youtube.com/watch?v={vid}\n")
    f.write(f"- date:    {upload}\n")
    f.write(f"- length:  {dur}\n\n")
    f.write("---\n\n")
    f.write(text + "\n")
PY
                rm -f "$tmp_ttml"
                echo "  [ok]   $title"
            else
                echo "  [warn] no subs: $title"
            fi
        done
done

echo
echo "Done. Transcripts in ${OUT_DIR}/"
echo "Have Claude digest a channel:  cd ~/llm-scripts && cc"
echo "Then ask: 'summarize new findings in docs/transcripts/<channel>/'"
