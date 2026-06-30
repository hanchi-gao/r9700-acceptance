#!/usr/bin/env bash
# Launch the R9700 acceptance GUI as root, preserving the display environment.
# Called by r9700-acceptance.desktop — do not rename this file.
set -e
REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
exec sudo -E /usr/bin/python3 "$REPO/gui/main.py"
