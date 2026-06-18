#!/usr/bin/env bash
# deploy.sh — one-shot setup after `git clone` on a freshly assembled machine
# that has ONLY git + ROCm + GPU driver. Installs every other dependency the
# acceptance suite needs, then sanity-checks the environment.
#
# Usage:
#   ./deploy.sh              # install host deps, sanity-check, pre-build kernels
#
# No docker needed — burn-in uses self-contained HIP kernels (FMA + rocBLAS GEMM).
# Safe to re-run (idempotent). Needs sudo for apt.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[warn]\033[0m %s\n' "$*"; }

if ! command -v apt-get >/dev/null; then
  echo "ERROR: this installer targets Ubuntu/Debian (apt). Adapt for your distro." >&2
  exit 1
fi

say "Installing host packages (apt)"
HOST_PKGS=(
  pciutils fio stress-ng memtester smartmontools nvme-cli lm-sensors
  ipmitool dmidecode mcelog python3 python3-yaml jq build-essential
  git curl ca-certificates
)
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${HOST_PKGS[@]}" \
  && ok "host packages installed" || warn "some host packages failed — re-check apt output"

say "ROCm sanity"
if command -v rocm-smi >/dev/null && rocm-smi --showid >/dev/null 2>&1; then
  n="$(rocm-smi --showbus 2>/dev/null | grep -c 'PCI Bus')"
  ok "rocm-smi works — sees $n GPU(s)"
else
  warn "rocm-smi not working — ROCm/driver must be installed BEFORE this tool can run (./install_rocm.sh)"
fi
if command -v hipcc >/dev/null; then ok "hipcc present (builds the FMA hotspot kernel)"; \
  else warn "hipcc missing — install ROCm hip-dev"; fi
if ls /opt/rocm/lib/librocblas.so* >/dev/null 2>&1; then ok "rocBLAS present (builds the GEMM VRAM-burn kernel)"; \
  else warn "rocBLAS missing — install rocblas/rocblas-dev (ships with ROCm) for the VRAM-burn stage"; fi

# Pre-build the burn kernels so the first acceptance run doesn't pay for it.
say "Pre-build GPU burn kernels"
ARCH="$(rocminfo 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | head -1)"; ARCH="${ARCH:-gfx1201}"
mkdir -p "$REPO_ROOT/build"
if command -v hipcc >/dev/null; then
  hipcc --offload-arch="$ARCH" -O3 "$REPO_ROOT/src/gpu_burn.hip"  -o "$REPO_ROOT/build/gpu_burn" 2>/dev/null \
    && ok "built build/gpu_burn (FMA)"  || warn "gpu_burn build failed (check hipcc)"
  hipcc --offload-arch="$ARCH" -O3 "$REPO_ROOT/src/gemm_burn.hip" -o "$REPO_ROOT/build/gemm_burn" -lrocblas 2>/dev/null \
    && ok "built build/gemm_burn (GEMM)" || warn "gemm_burn build failed (check rocBLAS)"
fi

chmod +x "$REPO_ROOT"/*.sh "$REPO_ROOT"/stress/*.sh 2>/dev/null || true

say "Next steps"
cat <<EOF
  1) Edit expected_config.yaml to match THIS machine class (NUMA, RAM, NVMe, VRAM).
  2) Verify:   ./preflight.sh    &&    ./inventory.sh
  3) Full run: ./run_acceptance.sh --serial <SERIAL> --duration 30m
  (No docker required — burn-in uses self-contained HIP kernels.)
EOF
