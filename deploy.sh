#!/usr/bin/env bash
# deploy.sh — one-shot setup after `git clone` on a freshly assembled machine
# that has ONLY git + ROCm + GPU driver. Installs every other dependency the
# acceptance suite needs, then sanity-checks the environment.
#
# Usage:
#   ./deploy.sh              # install host deps + docker, set sysctl
#   ./deploy.sh --pull       # ALSO docker-pull the (large) vLLM image now
#
# Safe to re-run (idempotent). Needs sudo for apt / docker / sysctl.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PULL_IMAGE=0
[[ "${1:-}" == "--pull" ]] && PULL_IMAGE=1

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

say "Docker"
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  ok "docker already usable"
else
  if ! command -v docker >/dev/null; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io \
      && ok "docker.io installed" || warn "docker.io install failed"
  fi
  sudo systemctl enable --now docker 2>/dev/null && ok "docker service enabled"
  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER" \
      && warn "added $USER to 'docker' group — LOG OUT/IN (or run: newgrp docker) before using docker without sudo"
  fi
fi

say "Kernel sysctl for vLLM (kernel.numa_balancing=0)"
if [[ "$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)" == "0" ]]; then
  ok "numa_balancing already 0"
else
  echo 'kernel.numa_balancing=0' | sudo tee /etc/sysctl.d/99-acceptance.conf >/dev/null
  sudo sysctl -w kernel.numa_balancing=0 >/dev/null && ok "numa_balancing set to 0 (persisted)"
fi

say "ROCm sanity"
if command -v rocm-smi >/dev/null && rocm-smi --showid >/dev/null 2>&1; then
  n="$(rocm-smi --showbus 2>/dev/null | grep -c 'PCI Bus')"
  ok "rocm-smi works — sees $n GPU(s)"
else
  warn "rocm-smi not working — ROCm/driver must be installed BEFORE this tool can run"
fi
command -v hipcc >/dev/null && ok "hipcc present (gpu-burn fallback can build)" \
  || warn "hipcc missing — install ROCm hip-dev for the gpu-burn fallback"

VRAM_IMAGE="${VRAM_IMAGE:-asrock_henrygao/rocm-vllm:rocm7.1_ubuntu22.04_py3.12_pytorch_release_2.9.0_vllm0.13.0}"
say "vLLM container image"
if (( PULL_IMAGE == 1 )); then
  echo "  pulling $VRAM_IMAGE (large, may take a while)..."
  docker pull "$VRAM_IMAGE" && ok "image pulled" || warn "image pull failed"
else
  if docker image inspect "$VRAM_IMAGE" >/dev/null 2>&1; then
    ok "image already present"
  else
    warn "image NOT pulled. Run: ./deploy.sh --pull   (or) docker pull $VRAM_IMAGE"
  fi
fi

chmod +x "$REPO_ROOT"/*.sh "$REPO_ROOT"/stress/*.sh 2>/dev/null || true

say "Next steps"
cat <<EOF
  1) If you were just added to the 'docker' group: log out/in (or 'newgrp docker').
  2) Edit expected_config.yaml to match THIS machine class (NUMA, RAM, NVMe, VRAM).
  3) Verify:   ./preflight.sh    &&    ./inventory.sh
  4) Full run: ./run_acceptance.sh --serial <SERIAL> --duration 30m
EOF
