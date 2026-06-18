#!/usr/bin/env bash
# install_rocm.sh — one-click ROCm + amdgpu driver install for Ubuntu.
# Follows the official quick-start:
#   https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html
#
# Run this FIRST on a freshly assembled machine (before ./deploy.sh). It installs
# the amdgpu kernel driver + ROCm, then a reboot is required. After reboot, run
# ./deploy.sh to install the rest of the acceptance-suite dependencies.
#
# Usage:
#   ./install_rocm.sh                 # install ROCm (default version), then prompt to reboot
#   ./install_rocm.sh --reboot        # reboot automatically when finished
#   ROCM_VERSION=7.2.4 ./install_rocm.sh
#   AMDGPU_DEB_URL=<full .deb url> ./install_rocm.sh   # override the installer .deb
#
# Defaults match the 4xR9700 target (gfx1201 needs ROCm 7.x, kernel >= 6.11).

set -uo pipefail

ROCM_VERSION="${ROCM_VERSION:-7.2.4}"
AMDGPU_BUILD="${AMDGPU_BUILD:-7.2.4.70204-1}"   # the .deb's build suffix for this version
AUTO_REBOOT=0
[[ "${1:-}" == "--reboot" ]] && AUTO_REBOOT=1

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Sanity ---------------------------------------------------------------
command -v apt-get >/dev/null || die "this installer targets Ubuntu (apt). See ROCm docs for your distro."
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
. /etc/os-release
CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -z "$CODENAME" ]] && die "could not detect Ubuntu codename"
case "$CODENAME" in
  noble|jammy) ok "Ubuntu $VERSION_ID ($CODENAME)";;
  *) warn "untested Ubuntu codename '$CODENAME' — proceeding with quick-start anyway";;
esac

KVER="$(uname -r | grep -oE '^[0-9]+\.[0-9]+')"
if awk -v k="$KVER" 'BEGIN{split(k,x,".");exit !(x[1]>6||(x[1]==6&&x[2]>=11))}'; then
  ok "kernel $(uname -r) >= 6.11 (gfx1201 / PCI id 1002:7551 will enumerate)"
else
  warn "kernel $(uname -r) < 6.11 — gfx1201 will NOT enumerate. Installing HWE kernel is recommended:"
  warn "  sudo apt install -y linux-generic-hwe-24.04 && reboot   (then re-run this script)"
fi

# --- Already installed? ---------------------------------------------------
if command -v rocm-smi >/dev/null && rocm-smi --showid >/dev/null 2>&1; then
  cur="$(grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' /opt/rocm/.info/version 2>/dev/null | head -1)"
  ok "ROCm already installed (version ${cur:-unknown}). Nothing to do."
  ok "If you want to (re)install version $ROCM_VERSION, remove ROCm first or run amdgpu-install manually."
  exit 0
fi

DEB_URL="${AMDGPU_DEB_URL:-https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${CODENAME}/amdgpu-install_${AMDGPU_BUILD}_all.deb}"
DEB_FILE="/tmp/$(basename "$DEB_URL")"

say "1/5  Add $USER to render,video groups (GPU access)"
sudo usermod -a -G render,video "$LOGNAME" && ok "added $LOGNAME to render,video (re-login to take effect)"

say "2/5  Register AMD repository (amdgpu-install package)"
echo "  downloading $DEB_URL"
if command -v wget >/dev/null; then
  wget -q -O "$DEB_FILE" "$DEB_URL" || die "download failed — check ROCM_VERSION/AMDGPU_BUILD or set AMDGPU_DEB_URL. See ROCm quick-start docs."
else
  curl -fsSL -o "$DEB_FILE" "$DEB_URL" || die "download failed — check version or set AMDGPU_DEB_URL."
fi
sudo apt-get install -y "$DEB_FILE" || die "installing amdgpu-install package failed"
sudo apt-get update -qq && ok "AMD repo registered"

say "3/5  Install amdgpu kernel driver (DKMS)"
sudo apt-get install -y "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)" \
  || warn "kernel headers/modules-extra install reported an issue (may already be present)"
sudo apt-get install -y amdgpu-dkms && ok "amdgpu-dkms installed" || die "amdgpu-dkms install failed"

say "4/5  Install ROCm"
sudo apt-get install -y python3-setuptools python3-wheel
sudo apt-get install -y rocm && ok "ROCm $ROCM_VERSION installed" || die "rocm install failed"

say "5/5  Done — REBOOT required"
cat <<EOF
  ROCm + amdgpu driver are installed. A reboot is REQUIRED to load the driver.
  After reboot, verify with:   rocm-smi
  Then run:                    ./deploy.sh    (installs acceptance-suite deps)
EOF

if (( AUTO_REBOOT == 1 )); then
  warn "rebooting in 5s (Ctrl-C to cancel)..."; sleep 5; sudo reboot
else
  echo
  read -r -p "  Reboot now? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] && sudo reboot || warn "remember to reboot before running the acceptance suite."
fi
