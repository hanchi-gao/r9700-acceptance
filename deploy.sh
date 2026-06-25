#!/usr/bin/env bash
# deploy.sh — one-shot setup after `git clone` on a fresh Ubuntu 24.04 machine.
# Installs all dependencies, builds the Vulkan GPU burn binary, and optionally
# sets up the GUI and LLM test. NO ROCm needed for the core burn-in suite.
#
# Usage:
#   ./deploy.sh              # install deps, build Vulkan burn, setup GUI
#   ./deploy.sh --with-llm   # also build llama.cpp (Vulkan) for LLM bench
#
# Safe to re-run (idempotent). Needs sudo for apt.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

WITH_LLM=0
[[ "${1:-}" == "--with-llm" ]] && WITH_LLM=1

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
fail(){ printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }

if ! command -v apt-get >/dev/null; then
  echo "ERROR: this installer targets Ubuntu/Debian (apt)." >&2; exit 1
fi

# ── 1. Host packages ─────────────────────────────────────────────────
say "Installing host packages (apt)"
HOST_PKGS=(
  # burn-in tools
  pciutils fio stress-ng memtester smartmontools nvme-cli lm-sensors
  ipmitool dmidecode jq
  # build tools
  build-essential cmake python3 python3-yaml python3-pip
  git curl ca-certificates
  # Vulkan (GPU burn + LLM)
  libvulkan-dev glslang-tools glslc spirv-headers mesa-vulkan-drivers
)
sudo apt-get update -qq
failed_pkgs=()
for pkg in "${HOST_PKGS[@]}"; do
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
    ok "$pkg"
  else
    failed_pkgs+=("$pkg"); warn "$pkg failed to install"
  fi
done
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mcelog >/dev/null 2>&1 \
  && ok "mcelog (optional)" || warn "mcelog unavailable — MCE detection falls back to dmesg"
(( ${#failed_pkgs[@]} == 0 )) && ok "all host packages installed" \
  || warn "missing: ${failed_pkgs[*]} — re-run or install manually"

# ── 2. Build Vulkan GPU burn ─────────────────────────────────────────
say "Building Vulkan GPU burn binary"
mkdir -p "$REPO_ROOT/build"

SPV="$REPO_ROOT/build/vk_burn.comp.spv"
if command -v glslangValidator >/dev/null; then
  glslangValidator -V "$REPO_ROOT/src/vk_burn.comp" -o "$SPV" 2>/dev/null \
    && ok "compiled shader → vk_burn.comp.spv" \
    || fail "shader compilation failed"
else
  fail "glslangValidator not found — install glslang-tools"
fi

if [[ -f "$SPV" ]]; then
  g++ -O2 "$REPO_ROOT/src/vk_burn.cpp" -o "$REPO_ROOT/build/vk_burn" -lvulkan 2>/dev/null \
    && ok "built build/vk_burn" \
    || fail "vk_burn build failed — check libvulkan-dev"
fi

# ── 3. Legacy HIP kernels (optional, if ROCm is present) ─────────────
if command -v hipcc >/dev/null; then
  say "ROCm detected — building legacy HIP kernels (optional)"
  ARCH="$(rocminfo 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | head -1)"; ARCH="${ARCH:-gfx1201}"
  hipcc --offload-arch="$ARCH" -O3 "$REPO_ROOT/src/gpu_burn.hip" -o "$REPO_ROOT/build/gpu_burn" 2>/dev/null \
    && ok "built build/gpu_burn (FMA)" || warn "gpu_burn build failed"
  hipcc --offload-arch="$ARCH" -O3 "$REPO_ROOT/src/gemm_burn.hip" -o "$REPO_ROOT/build/gemm_burn" -lrocblas 2>/dev/null \
    && ok "built build/gemm_burn (GEMM)" || warn "gemm_burn build failed"
fi

# ── 4. GUI dependencies ──────────────────────────────────────────────
say "Installing GUI dependencies (pip)"
pip3 install PyQt6 pyqtgraph --quiet --break-system-packages 2>/dev/null \
  && ok "PyQt6 + pyqtgraph" \
  || warn "pip install failed — GUI may not work"

# ── 5. LLM test (optional) ───────────────────────────────────────────
if (( WITH_LLM )); then
  say "Building llama.cpp (Vulkan backend) for LLM bench"
  LLAMA_DIR="$REPO_ROOT/third_party/llama.cpp"
  if [[ ! -d "$LLAMA_DIR" ]]; then
    git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR" 2>/dev/null \
      && ok "cloned llama.cpp" || fail "git clone failed"
  fi
  if [[ -d "$LLAMA_DIR" ]]; then
    cmake -B "$LLAMA_DIR/build_vk" -S "$LLAMA_DIR" \
      -DGGML_VULKAN=ON -DGGML_HIP=OFF \
      -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 \
      && cmake --build "$LLAMA_DIR/build_vk" --target llama-cli -j"$(nproc)" >/dev/null 2>&1 \
      && cp "$LLAMA_DIR/build_vk/bin/llama-cli" "$REPO_ROOT/build/llama-cli" \
      && ok "built build/llama-cli (Vulkan)" \
      || fail "llama.cpp build failed — need: libvulkan-dev glslc spirv-headers"
  fi
  if ls "$REPO_ROOT/models/"*.gguf >/dev/null 2>&1; then
    ok "found model(s) in models/"
  else
    warn "no .gguf model found in models/ — place a .gguf file in models/"
    warn "  e.g.: Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf (~4.5GB)"
  fi
else
  say "LLM test skipped (use --with-llm to enable; requires ROCm)"
fi

# ── 6. Sanity check ──────────────────────────────────────────────────
say "Sanity check"
# Vulkan
if command -v vulkaninfo >/dev/null 2>&1; then
  n="$(vulkaninfo --summary 2>/dev/null | grep -c 'GPU' || true)"
  ok "Vulkan sees $n GPU(s)"
else
  # Count amdgpu hwmon as fallback
  n=0
  for d in /sys/class/hwmon/hwmon*; do
    [[ "$(cat "$d/name" 2>/dev/null)" == "amdgpu" ]] && n=$((n+1))
  done
  ok "sysfs sees $n amdgpu device(s)"
fi
[[ -x "$REPO_ROOT/build/vk_burn" ]] && ok "vk_burn ready" || fail "vk_burn not built"

chmod +x "$REPO_ROOT"/*.sh "$REPO_ROOT"/stress/*.sh 2>/dev/null || true

say "Done"
cat <<EOF
  Quick start:
    ./preflight.sh                                    # environment check
    ./inventory.sh                                    # hardware vs config
    ./run_acceptance.sh --serial SN001 --duration 30m # full burn-in
    python3 gui/main.py                               # monitoring GUI

  No ROCm required for burn-in. GPU stress uses Vulkan compute.
EOF
