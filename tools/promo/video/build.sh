#!/usr/bin/env bash
# Rebuild the Overlock promo video from the repository footage, music and timeline.
#
#   tools/promo/video/build.sh [all|video|verify]
#
# Environment:
#   PY    python with numpy, pillow, skia-python, soundfile, librosa (see README.md)
#   WORK  scratch directory for large intermediates (default: $TMPDIR/overlock_promo_work, outside the repo)
#   CRF   x264 CRF for the 1080p60 master (default 16)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$ROOT/docs/promo/video"
PY="${PY:-python3}"
WORK="${WORK:-${TMPDIR:-/tmp}/overlock_promo_work}"
CRF="${CRF:-16}"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
MODE="${1:-all}"
# Apple AudioToolbox AAC keeps true peaks close to the source; ffmpeg's native encoder overshot by ~3 dB here.
if "$FFMPEG" -hide_banner -encoders 2>/dev/null | grep -q " aac_at "; then AAC="aac_at"; else AAC="aac"; fi

mkdir -p "$WORK"
cd "$HERE"

FINAL="$OUT/overlock_promo_1080p60.mp4"
SMALL="$OUT/overlock_promo_720p.mp4"

if [[ "$MODE" == "all" || "$MODE" == "video" ]]; then
  echo "== resolved timeline"
  "$PY" render.py --export-timeline "$OUT/timeline.json"

  echo "== music (beat-grid cut, fades, loudness)"
  "$PY" audio.py "$WORK/music.wav" "$WORK"

  echo "== composite + encode 1080p60 video"
  "$PY" render.py --out "$WORK/video.mp4" --crf "$CRF"

  echo "== mux"
  "$FFMPEG" -v error -y -i "$WORK/video.mp4" -i "$WORK/music.wav" \
    -map 0:v:0 -map 1:a:0 -c:v copy -c:a "$AAC" -b:a 256k -ar 48000 -ac 2 \
    -metadata title="OVERLOCK" -metadata:s:a:0 handler_name="Newer Wave - Kevin MacLeod (CC BY 4.0)" \
    -movflags +faststart "$FINAL"

  echo "== 720p share copy (30 fps, 2-pass)"
  "$FFMPEG" -v error -y -i "$FINAL" -an \
    -vf "fps=30,scale=1280:720:flags=lanczos:in_color_matrix=bt709:out_color_matrix=bt709:in_range=tv:out_range=tv,format=yuv420p" \
    -c:v libx264 -preset slow -b:v 2350k -pass 1 -passlogfile "$WORK/x264_720" -profile:v high \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv -f null /dev/null
  "$FFMPEG" -v error -y -i "$FINAL" \
    -vf "fps=30,scale=1280:720:flags=lanczos:in_color_matrix=bt709:out_color_matrix=bt709:in_range=tv:out_range=tv,format=yuv420p" \
    -c:v libx264 -preset slow -b:v 2350k -pass 2 -passlogfile "$WORK/x264_720" -profile:v high \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
    -map 0:v:0 -map 0:a:0 -c:a copy -movflags +faststart "$SMALL"

  echo "== poster and storyboard"
  "$PY" sheets.py poster "$FINAL" "${POSTER_FRAME:-2500}" "$OUT/overlock_promo_poster.jpg"
  "$PY" sheets.py storyboard "$FINAL" "$OUT/timeline.json" "$OUT/storyboard.jpg"
fi

if [[ "$MODE" == "all" || "$MODE" == "verify" ]]; then
  echo "== debug render (beat marker, not for delivery)"
  "$PY" render.py --out "$WORK/debug_v.mp4" --crf 26 --debug-beats
  "$FFMPEG" -v error -y -i "$WORK/debug_v.mp4" -i "$WORK/music.wav" -map 0:v:0 -map 1:a:0 \
    -c:v copy -c:a "$AAC" -b:a 256k -movflags +faststart "$WORK/debug.mp4"

  echo "== verify"
  "$PY" verify.py spec "$FINAL" > "$WORK/spec.json"
  "$PY" verify.py cuts "$FINAL" "$OUT/timeline.json" "$WORK/cuts.json"
  "$PY" verify.py audio "$FINAL" "$WORK/song_48k.wav" "$OUT/timeline.json" "$WORK/audio_sync.json"
  "$PY" verify.py debug "$WORK/debug.mp4" "$OUT/timeline.json" "$WORK/debug_sync.json"
  "$PY" verify.py loud "$FINAL"
  "$PY" verify.py dark "$FINAL" "$OUT/timeline.json"
fi
