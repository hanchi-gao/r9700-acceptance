#!/usr/bin/env bash
# package.sh — build the offline self-extracting installer.
# Run on an internet-connected Ubuntu 24.04 machine (the dev box).
#
# Output: r9700-acceptance.run   (~300-500 MB)
# Usage on factory machine: sudo bash r9700-acceptance.run

set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
OUT="$REPO/r9700-acceptance.run"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
step()  { echo -e "\n${YELLOW}==>${NC} $*"; }

echo "=== R9700 Acceptance — offline bundle builder ==="
echo "    Output: $OUT"

# ── prerequisites ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && { echo "Run WITHOUT sudo (apt-get download runs as user)"; exit 1; }
command -v apt-get   >/dev/null || { echo "Needs Ubuntu/Debian"; exit 1; }
command -v pip3      >/dev/null || { echo "pip3 not found — sudo apt install python3-pip"; exit 1; }
command -v rsync     >/dev/null || { sudo apt-get install -y rsync; }

# ── check vk_burn ────────────────────────────────────────────────────────────
step "Checking build artifacts"
if [[ ! -f "$REPO/build/vk_burn" ]]; then
  echo "  vk_burn not found — running deploy.sh first..."
  bash "$REPO/deploy.sh"
fi
info "vk_burn: $(file "$REPO/build/vk_burn" | cut -d, -f1)"

# ── staging area ─────────────────────────────────────────────────────────────
STAGE="$(mktemp -d)"
trap "echo 'Cleaning up...'; rm -rf '$STAGE'" EXIT
BUNDLE="$STAGE/bundle"
mkdir -p "$BUNDLE"/{debs,wheels}

# ── download apt packages ────────────────────────────────────────────────────
step "Downloading apt packages (this may take a few minutes)"

APT_PKGS=(
  stress-ng fio memtester smartmontools jq pciutils dmidecode
  python3-pyqt6 python3-numpy python3-yaml
  dpkg-dev    # for dpkg-scanpackages (used by install.sh)
)

# Resolve full dependency tree (excluding virtual packages)
echo "  Resolving dependency tree..."
DEP_LIST=$(apt-cache depends --recurse --no-recommends --no-suggests \
  --no-conflicts --no-breaks --no-replaces --no-enhances \
  "${APT_PKGS[@]}" 2>/dev/null \
  | grep "^[a-zA-Z0-9]" | grep -v "^<" | sort -u)

echo "  Downloading $(echo "$DEP_LIST" | wc -w) packages..."
pushd "$BUNDLE/debs" > /dev/null
FAILED=()
while IFS= read -r pkg; do
  apt-get download "$pkg" 2>/dev/null || FAILED+=("$pkg")
done <<< "$DEP_LIST"
popd > /dev/null

# Also directly download the top-level packages to ensure we have them
pushd "$BUNDLE/debs" > /dev/null
apt-get download "${APT_PKGS[@]}" 2>/dev/null || true
popd > /dev/null

DEB_COUNT=$(ls "$BUNDLE/debs"/*.deb 2>/dev/null | wc -l)
info "$DEB_COUNT .deb files downloaded"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  warn "Could not download: ${FAILED[*]}"
fi

# ── download pip wheels ──────────────────────────────────────────────────────
step "Downloading pip wheels"

# pyqtgraph: not always in apt, download wheel as fallback
pip3 download pyqtgraph --no-deps -d "$BUNDLE/wheels" --quiet
WHEEL_COUNT=$(ls "$BUNDLE/wheels"/*.whl 2>/dev/null | wc -l)
info "$WHEEL_COUNT wheel(s) downloaded"

# ── copy repo ────────────────────────────────────────────────────────────────
step "Copying repo"
rsync -a \
  --exclude='.git' \
  --exclude='results/' \
  --exclude='models/' \
  --exclude='third_party/' \
  --exclude='web/' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='*.gguf' \
  --exclude='*.bin' \
  --exclude='r9700-acceptance.run' \
  --exclude='*.desktop' \
  --exclude='安裝R9700燒機套件.sh' \
  --exclude='package.sh' \
  "$REPO/" "$BUNDLE/repo/"
# Place install.sh at bundle root (the .run script looks for bundle/install.sh)
cp "$REPO/install.sh" "$BUNDLE/install.sh"
chmod +x "$BUNDLE/install.sh" "$BUNDLE/repo/install.sh"
info "Repo copied ($(du -sh "$BUNDLE/repo" | cut -f1))"

# ── create archive + self-extracting wrapper ──────────────────────────────────
step "Creating self-extracting bundle"
echo "  Compressing... (may take 1-2 min)"
tar -czf "$STAGE/payload.tar.gz" -C "$STAGE" bundle

PAYLOAD_LINES=$(wc -l < "$STAGE/payload.tar.gz" 2>/dev/null || echo 0)
ARCHIVE_SIZE=$(du -sh "$STAGE/payload.tar.gz" | cut -f1)
info "Archive: $ARCHIVE_SIZE"

echo "  Encoding..."
# Write the bash header
cat > "$OUT" << 'HEADER_EOF'
#!/usr/bin/env bash
# R9700 Acceptance Test Suite — offline self-extracting installer
# Usage:  sudo bash r9700-acceptance.run
#
# What this does (first run):
#   1. Install apt packages offline (stress-ng, fio, PyQt6, etc.)
#   2. Install pyqtgraph pip wheel
#   3. Copy suite to /opt/r9700-acceptance/
#   4. Configure passwordless sudo for the GUI
#   5. Create desktop shortcut (double-click to launch)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  SELF="$(readlink -f "$0")"
  # If running inside a terminal, just re-exec with sudo
  if [[ -t 0 ]]; then
    exec sudo bash "$SELF" "$@"
  fi
  # No terminal (double-clicked in Nautilus) — open one
  if command -v gnome-terminal &>/dev/null; then
    exec gnome-terminal -- bash -c "sudo bash '$SELF'; echo; read -rp 'Press Enter to close...'"
  elif command -v x-terminal-emulator &>/dev/null; then
    exec x-terminal-emulator -e bash -c "sudo bash '$SELF'; echo; read -rp 'Press Enter to close...'"
  else
    exec sudo bash "$SELF" "$@"
  fi
fi

echo ""
echo "  ██████╗  █████╗ ███████╗███████╗ ██████╗  ██████╗  ██████╗ "
echo "  ██╔══██╗██╔══██╗██╔════╝██╔════╝██╔══██╗██╔════╝ ██╔═══██╗"
echo "  ██████╔╝╚██████║█████╗  ███████╗██████╔╝███████╗ ██║   ██║"
echo "  ██╔══██╗ ╚═══██║██╔══╝  ╚════██║██╔══██╗██╔═══██╗██║   ██║"
echo "  ██║  ██║ █████╔╝███████╗███████║██║  ██║╚██████╔╝╚██████╔╝"
echo "  ╚═╝  ╚═╝ ╚════╝ ╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ "
echo ""
echo "  R9700 Acceptance Test Suite — Offline Installer"
echo ""

TMPDIR_INST="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_INST"; }
trap cleanup EXIT

echo "Extracting bundle..."
SKIP=$(grep -n "^__PAYLOAD_B64__$" "$0" | cut -d: -f1)
tail -n +"$((SKIP + 1))" "$0" | base64 -d | tar -xzf - -C "$TMPDIR_INST"

bash "$TMPDIR_INST/bundle/install.sh" "$TMPDIR_INST/bundle"
exit 0

__PAYLOAD_B64__
HEADER_EOF

# Append base64-encoded payload
base64 "$STAGE/payload.tar.gz" >> "$OUT"
chmod +x "$OUT"

FINAL_SIZE=$(du -sh "$OUT" | cut -f1)

# Write a companion .sh launcher — double-click → "Run in Terminal" → sudo password
INSTALLER_SH="$(dirname "$OUT")/安裝R9700燒機套件.sh"
cat > "$INSTALLER_SH" << 'SHEOF'
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
SHEOF
chmod +x "$INSTALLER_SH"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Bundle created successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "  Files:"
echo "    $OUT  ($FINAL_SIZE)"
echo "    $INSTALLER_SH"
echo ""
echo "  Copy BOTH files to USB / Desktop. On the factory machine:"
echo "    → Double-click '安裝R9700燒機套件.sh' → click 'Run in Terminal'"
echo "    → Enter sudo password once"
echo "    → After install: double-click ~/Desktop/R9700 Acceptance icon"
echo ""
