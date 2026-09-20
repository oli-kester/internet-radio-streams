#!/usr/bin/env bash
# Sample each stream and report EBU R128 loudness, loudness range and true peak.
#
# This is a DIAGNOSTIC, not a calibration. These are live stations: loudness
# moves when the show or the DJ changes, so a single sample describes this
# moment only. Treat a high LRA as "this sample is not representative" and a
# true peak at or above 0 dBFS as "already clipping, do not add gain".
#
# Usage: tools/measure-loudness.sh [playlist.xspf] [seconds]
set -uo pipefail

PLAYLIST="${1:-$(dirname "$0")/../vlc-internet-radio.xspf}"
DURATION="${2:-45}"
UA="VLC/3.0.21 LibVLC/3.0.21"

FFMPEG=$(command -v ffmpeg 2>/dev/null) || true
if [ -z "${FFMPEG:-}" ]; then
    for candidate in \
        "$LOCALAPPDATA/Programs/ffmpeg/bin/ffmpeg.exe" \
        "/c/Program Files/ffmpeg/bin/ffmpeg.exe"; do
        [ -x "$candidate" ] && { FFMPEG="$candidate"; break; }
    done
fi
[ -n "${FFMPEG:-}" ] || { echo "ffmpeg not found — install it or put it on PATH" >&2; exit 2; }
[ -r "$PLAYLIST" ] || { echo "cannot read playlist: $PLAYLIST" >&2; exit 2; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

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

echo "Sampling ${DURATION}s of each stream..."
while IFS=$'\t' read -r idx title url; do
    (
        report=$("$FFMPEG" -hide_banner -nostdin -user_agent "$UA" \
                 -i "$url" -t "$DURATION" -af ebur128=peak=true -f null - 2>&1)
        extract() { grep -aA6 "$1" <<<"$report" | grep -aoE "$2: *-?[0-9.]+" | tail -1 | grep -oE '\-?[0-9.]+'; }
        lufs=$(extract "Integrated loudness" "I")
        lra=$(extract "Loudness range" "LRA")
        peak=$(extract "True peak" "Peak")
        printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$title" "${lufs:-n/a}" "${lra:-n/a}" "${peak:-n/a}"
    ) > "$workdir/$idx.result" &
done < "$workdir/tracks.tsv"
wait

printf '\n%4s  %8s  %6s  %7s  %s\n' "#" "LUFS" "LRA" "PEAK" "STATION"
while IFS=$'\t' read -r idx title lufs lra peak; do
    printf '%4s  %8s  %6s  %7s  %s\n' "$idx" "$lufs" "$lra" "$peak" "${title:0:44}"
done < <(cat "$workdir"/*.result | sort -n)

cat <<'NOTE'

LUFS = perceived loudness (less negative is louder)
LRA  = loudness range; above ~10 means this sample is not representative
PEAK = true peak in dBFS; at or above 0 the stream is already clipping
NOTE
