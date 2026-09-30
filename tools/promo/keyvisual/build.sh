#!/usr/bin/env bash
# Rebuild every key visual deliverable in docs/promo/.
# Usage: tools/promo/keyvisual/build.sh [venv_dir]
# The venv (Pillow + numpy) defaults to tools/promo/keyvisual/.venv and is
# created on first run.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
venv="${1:-$here/.venv}"

if [ ! -x "$venv/bin/python" ]; then
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet -r "$here/requirements.txt"
fi

"$venv/bin/python" "$here/make_keyvisual.py" --final
