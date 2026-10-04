#!/usr/bin/env bash
# Cut the two itch.io page GIFs out of the 1080p60 promo video.
# Usage: tools/promo/itch/make_gifs.sh [out_dir]   (default docs/promo/itch)
#
# -ss/-t sit before each -i so ffmpeg seeks the input and decodes from the
# previous keyframe, dropping frames up to the exact start (accurate cut).
# Both GIFs: 640 px wide, 12 fps, one palette per clip. The promo footage is a
# moving camera over textured fabric, so a straight 256-colour GIF is ~5 MB; a
# light temporal denoise (hqdn3d), a 96-colour palette (diff stats) and a coarse
# bayer dither bring each clip under 3 MB without visible banding on the fabric.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
out="${1:-$root/docs/promo/itch}"
video="$root/docs/promo/video/overlock_promo_1080p60.mp4"
ffmpeg="${FFMPEG:-ffmpeg}"
command -v "$ffmpeg" >/dev/null || ffmpeg=/opt/homebrew/bin/ffmpeg

mkdir -p "$out"
pal="fps=12,scale=640:-2:flags=lanczos,hqdn3d=8:6:0:0,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
common=(-hide_banner -loglevel error -y -bitexact)

# drift fold: 18.00-21.80 s. The DRIFT stamp + Shift keycap (drift_silk shot from
# 18.0 s) followed by the long fold shot (19.09-21.82 s, "원단이 접혀 올라온다!").
# Stops before the cut to the mom's chance shot at 21.82 s.
"$ffmpeg" "${common[@]}" -ss 18.00 -t 3.80 -i "$video" \
    -filter_complex "[0:v]$pal" -loop 0 "$out/gif_drift_fold.gif"

# ghost + item: the ghost shot (15.30-17.45 s) followed by the mom's chance item
# shot (21.85-24.00 s), joined into one 4.3 s loop
"$ffmpeg" "${common[@]}" -ss 15.30 -t 2.15 -i "$video" -ss 21.85 -t 2.15 -i "$video" \
    -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0[c];[c]$pal" -loop 0 "$out/gif_ghost_items.gif"

for g in gif_drift_fold gif_ghost_items; do
    f="$out/$g.gif"
    n=$("${ffmpeg%ffmpeg}ffprobe" -v error -count_frames -select_streams v:0 \
        -show_entries stream=nb_read_frames -of csv=p=0 "$f" 2>/dev/null || echo "?")
    echo "wrote $f ($(wc -c <"$f" | tr -d ' ') bytes, $n frames)"
done
