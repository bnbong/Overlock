#!/usr/bin/env bash
# Rebuild every itch.io page asset in docs/promo/itch/ (stills, previews, GIFs).
# Usage: tools/promo/itch/build.sh [venv_dir]
# The venv (Pillow + numpy, pinned in tools/promo/keyvisual/requirements.txt)
# defaults to tools/promo/itch/.venv and is created on first run. The GIF step
# needs ffmpeg on PATH (or FFMPEG=/path/to/ffmpeg).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
venv="${1:-$here/.venv}"

if [ ! -x "$venv/bin/python" ]; then
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet -r "$here/../keyvisual/requirements.txt"
fi

"$venv/bin/python" "$here/make_itch_assets.py"
"$here/make_gifs.sh"
