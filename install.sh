#!/usr/bin/env bash
# install.sh — offline installer, runs inside the self-extracting .run bundle.
# Called as:  bash install.sh <bundle_dir>
# Must be run as root (sudo bash r9700-acceptance.run).

set -euo pipefail

BUNDLE="${1:-$(dirname "$(readlink -f "$0")")}"
INSTALL_DIR="/opt/r9700-acceptance"
SUDOERS_FILE="/etc/sudoers.d/r9700-gui"
DESKTOP_SYSTEM="/usr/share/applications/r9700-acceptance.desktop"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${YELLOW}==>${NC} $*"; }

# ── sanity checks ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Run as root: sudo bash r9700-acceptance.run"

. /etc/os-release 2>/dev/null || true
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  warn "Expected Ubuntu 24.04 (got ${PRETTY_NAME:-unknown}) — continuing anyway"
fi

# ── detect original (non-root) user for desktop shortcut ────────────────────
REAL_USER="${SUDO_USER:-${USER}}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

# ── Step 1: install apt packages from bundled .deb files ────────────────────
step "Installing system packages (offline)"
DEB_DIR="$BUNDLE/debs"
if [[ -d "$DEB_DIR" && -n "$(ls "$DEB_DIR"/*.deb 2>/dev/null)" ]]; then
  deb_count=$(ls "$DEB_DIR"/*.deb | wc -l)
  echo "  Found $deb_count .deb files"

  # Use apt with a local package source for proper dependency resolution
  APT_REPO="/tmp/r9700-apt-repo"
  mkdir -p "$APT_REPO"
  cp "$DEB_DIR"/*.deb "$APT_REPO/"

  # Build package index for local repo
  ( cd "$APT_REPO" && dpkg-scanpackages . 2>/dev/null ) \
    | gzip > "$APT_REPO/Packages.gz"

  # Add local repo as apt source
  cat > /etc/apt/sources.list.d/r9700-local.list \
    <<< "deb [trusted=yes] file://${APT_REPO} ./"
  apt-get update -o Dir::Etc::SourceList=/etc/apt/sources.list.d/r9700-local.list \
                 -o Dir::Etc::SourceListDir=/dev/null \
                 -q 2>/dev/null || true

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    --no-install-recommends \
    --allow-downgrades \
    -o Dir::Etc::SourceList=/etc/apt/sources.list.d/r9700-local.list \
    -o Dir::Etc::SourceListDir=/dev/null \
    stress-ng fio memtester smartmontools jq pciutils dmidecode \
    python3-pyqt6 python3-numpy python3-yaml \
    || {
      warn "apt install had issues — falling back to dpkg"
      for pass in 1 2 3; do
        dpkg --force-depends --force-confnew -i "$APT_REPO"/*.deb 2>&1 \
          | grep -E "(error|installed)" || true
      done
    }

  rm -f /etc/apt/sources.list.d/r9700-local.list
  rm -rf "$APT_REPO"
  info "System packages installed"
else
  warn "No .deb files found — skipping apt step"
fi

# ── Step 2: install Python packages ─────────────────────────────────────────
step "Installing Python packages"
WHEEL_DIR="$BUNDLE/wheels"

# Try apt pyqtgraph first (Ubuntu 24.04 has it)
if apt-cache show python3-pyqtgraph &>/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    python3-pyqtgraph 2>/dev/null && info "pyqtgraph installed via apt" \
  || true
fi

# Fallback to pip wheel
if ! python3 -c "import pyqtgraph" 2>/dev/null; then
  if [[ -d "$WHEEL_DIR" && -n "$(ls "$WHEEL_DIR"/*.whl 2>/dev/null)" ]]; then
    pip3 install --quiet --no-index --find-links="$WHEEL_DIR" pyqtgraph \
      && info "pyqtgraph installed via pip wheel" \
      || warn "pyqtgraph install failed — GUI charts may not work"
  else
    warn "No pyqtgraph wheel found"
  fi
fi

# Verify critical imports
python3 -c "import PyQt6, pyqtgraph, yaml" 2>/dev/null \
  && info "Python imports OK" \
  || warn "Some Python imports failed — GUI may not start"

# ── Step 3: install repo to /opt ─────────────────────────────────────────────
step "Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rsync -a --delete \
  --exclude='__pycache__' --exclude='*.pyc' --exclude='results/' \
  "$BUNDLE/repo/" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR"/stress/*.sh \
         "$INSTALL_DIR"/lib/*.sh "$INSTALL_DIR"/launch_gui.sh 2>/dev/null || true
info "Installed to $INSTALL_DIR"

# ── Step 4: install pre-compiled vk_burn ─────────────────────────────────────
step "Setting up GPU burn binary"
mkdir -p "$INSTALL_DIR/build"
if [[ -f "$BUNDLE/repo/build/vk_burn" ]]; then
  chmod +x "$INSTALL_DIR/build/vk_burn"
  info "vk_burn ready"
else
  warn "vk_burn not found in bundle — run ./deploy.sh on this machine to build it"
fi

# ── Step 5: sudoers — passwordless GUI launch ─────────────────────────────────
step "Configuring passwordless GUI launch"
PYTHON_BIN="$(readlink -f /usr/bin/python3)"
MAIN_PY="$INSTALL_DIR/gui/main.py"

cat > "$SUDOERS_FILE" << EOF
# R9700 Acceptance GUI — allow launch without password
$REAL_USER ALL=(ALL) NOPASSWD: $PYTHON_BIN $MAIN_PY
EOF
chmod 440 "$SUDOERS_FILE"
# Validate
visudo -c -f "$SUDOERS_FILE" 2>/dev/null \
  && info "sudoers entry OK ($SUDOERS_FILE)" \
  || { rm -f "$SUDOERS_FILE"; warn "sudoers validation failed — sudo will ask for password"; }

# Update launch_gui.sh to use absolute paths
cat > "$INSTALL_DIR/launch_gui.sh" << LAUNCH
#!/usr/bin/env bash
exec sudo -E $PYTHON_BIN $MAIN_PY
LAUNCH
chmod +x "$INSTALL_DIR/launch_gui.sh"

# ── Step 6: desktop entries ──────────────────────────────────────────────────
step "Creating desktop shortcuts"
ICON="system-run"  # fallback system icon
# Use our icon if bundled
[[ -f "$INSTALL_DIR/gui/icon.png" ]] && ICON="$INSTALL_DIR/gui/icon.png"

cat > "$DESKTOP_SYSTEM" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=R9700 Acceptance
Comment=Factory acceptance test suite for 4× ASRock Radeon AI PRO R9700
Exec=$INSTALL_DIR/launch_gui.sh
Icon=$ICON
Terminal=false
Categories=System;HardwareSettings;
StartupNotify=true
EOF

# Copy to actual user's desktop
DESKTOP_DIR="$REAL_HOME/Desktop"
mkdir -p "$DESKTOP_DIR"
cp "$DESKTOP_SYSTEM" "$DESKTOP_DIR/r9700-acceptance.desktop"
chown "$REAL_USER:$REAL_USER" "$DESKTOP_DIR/r9700-acceptance.desktop"
chmod +x "$DESKTOP_DIR/r9700-acceptance.desktop"

# Mark as trusted (GNOME won't show "run?" dialog)
sudo -u "$REAL_USER" gio set \
  "$DESKTOP_DIR/r9700-acceptance.desktop" \
  metadata::trusted true 2>/dev/null || true

info "Desktop shortcut: $DESKTOP_DIR/r9700-acceptance.desktop"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  R9700 Acceptance installed successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "  Double-click  ~/Desktop/r9700-acceptance.desktop  to launch"
echo "  Or run:       $INSTALL_DIR/launch_gui.sh"
echo ""
echo "  Config:       $INSTALL_DIR/expected_config.yaml"
echo "  Results:      $INSTALL_DIR/results/"
echo ""
