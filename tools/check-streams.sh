#!/usr/bin/env bash
# Verify every stream in the playlist actually delivers audio.
#
# A dead Icecast mount often still answers "200 OK" with an audio content-type
# and then sends nothing at all, so checking status codes and headers is not
# enough: this only passes a stream that really sends audio bytes.
#
# Usage: tools/check-streams.sh [playlist.xspf]
set -uo pipefail

PLAYLIST="${1:-$(dirname "$0")/../vlc-internet-radio.xspf}"
UA="VLC/3.0.21 LibVLC/3.0.21"
SAMPLE_SECONDS=12
MIN_BYTES=50000      # ~32 kbps sustained; any real stream clears this easily
MIN_HLS_SEGMENT=20000

[ -r "$PLAYLIST" ] || { echo "cannot read playlist: $PLAYLIST" >&2; exit 2; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# <location> and <title> pairs, in playlist order.
python - "$PLAYLIST" > "$workdir/tracks.tsv" <<'PY'
import html, io, re, sys
sys.stdout.reconfigure(newline="\n")  # keep LF on Windows
xml = io.open(sys.argv[1], encoding="utf-8").read()
for i, track in enumerate(re.findall(r"<track>(.*?)</track>", xml, re.S)):
    loc = re.search(r"<location>(.*?)</location>", track, re.S)
    title = re.search(r"<title>(.*?)</title>", track, re.S)
    if not loc:
        continue
    name = html.unescape(title.group(1)) if title else "(untitled)"
    sys.stdout.write("%d\t%s\t%s\n" % (i, name, html.unescape(loc.group(1))))
PY

check_hls() {
    # An HLS manifest is small and finishes instantly, so fetch a real segment.
    local url="$1" manifest segment base
    manifest=$(curl -sS -L --max-time 15 -A "$UA" "$url" 2>/dev/null)
    grep -q "#EXTM3U" <<<"$manifest" || { echo "0 no-manifest"; return; }
    segment=$(grep -v '^#' <<<"$manifest" | grep '[^[:space:]]' | head -1 | tr -d '\r')
    [ -n "$segment" ] || { echo "0 no-segments"; return; }
    case "$segment" in
        http*) ;;
        /*)    base=$(sed -E 's|(https?://[^/]+).*|\1|' <<<"$url"); segment="$base$segment" ;;
        *)     base=$(sed -E 's|/[^/]*$||' <<<"$url");             segment="$base/$segment" ;;
    esac
    echo "$(curl -sS -L --max-time 20 -A "$UA" -o /dev/null -w '%{size_download}' "$segment" 2>/dev/null) hls-segment"
}

check_stream() {
    curl -sS -L --max-time "$SAMPLE_SECONDS" -A "$UA" -H "Icy-MetaData: 1" \
         -o /dev/null -w '%{size_download} %{content_type}' "$1" 2>/dev/null
}

while IFS=$'\t' read -r idx title url; do
    (
        case "$url" in
            *.m3u8) read -r bytes detail <<<"$(check_hls "$url")";    floor=$MIN_HLS_SEGMENT ;;
            *)      read -r bytes detail <<<"$(check_stream "$url")"; floor=$MIN_BYTES ;;
        esac
        if [ "${bytes:-0}" -ge "$floor" ]; then
            printf '%s\tPASS\t%s\t%s\t%s\n' "$idx" "$title" "${bytes:-0}" "${detail:-}"
        else
            printf '%s\tFAIL\t%s\t%s\t%s\n' "$idx" "$title" "${bytes:-0}" "${detail:-no data}"
        fi
    ) > "$workdir/$idx.result" &
done < "$workdir/tracks.tsv"
wait

failures=0
while IFS=$'\t' read -r idx status title bytes detail; do
    printf '%-4s %2s  %-46s %s\n' "$status" "$idx" "${title:0:44}" "$detail"
    [ "$status" = "FAIL" ] && failures=$((failures + 1))
done < <(cat "$workdir"/*.result | sort -n)

total=$(wc -l < "$workdir/tracks.tsv")
echo
echo "$((total - failures))/$total streams delivering audio"
[ "$failures" -eq 0 ] || echo "$failures need attention — check for a moved mount before removing a station"
exit $(( failures > 0 ))
