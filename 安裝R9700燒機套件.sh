#!/usr/bin/env bash
# 安裝R9700燒機套件.sh
# Double-click in Nautilus → "Run in Terminal" → enter sudo password → done.
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RUN="$DIR/r9700-acceptance.run"

if [[ ! -f "$RUN" ]]; then
  echo "ERROR: r9700-acceptance.run not found in $DIR"
  echo "Make sure both files are in the same folder."
  read -rp "Press Enter to close..." _
  exit 1
fi

if [[ $EUID -eq 0 ]]; then
  bash "$RUN"
elif [[ -t 0 ]]; then
  exec sudo bash "$RUN"
else
  # No terminal (executed directly by file manager) — open one
  QUOTED_RUN="${RUN//\'/\'\\\'\'}"
  CMD="sudo bash '$QUOTED_RUN'; echo; read -rp 'Press Enter to close...' _"
  if command -v gnome-terminal &>/dev/null; then
    exec gnome-terminal -- bash -c "$CMD"
  elif command -v xterm &>/dev/null; then
    exec xterm -e bash -c "$CMD"
  else
    exec sudo bash "$RUN"
  fi
fi
