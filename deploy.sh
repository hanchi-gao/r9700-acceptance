#!/usr/bin/env bash
# deploy.sh — one-shot setup on a fresh Ubuntu 24.04 machine.
# Installs dependencies, installs gfx1201 firmware, builds vk_burn.
#
# Usage:
#   ./deploy.sh              # core burn-in suite
#   ./deploy.sh --with-llm   # also build llama.cpp (Vulkan) for LLM bench
#
# Safe to re-run (idempotent). Needs sudo for apt + firmware install.

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

# ── 1. Kernel version check ───────────────────────────────────────────
say "Kernel check"
KVER="$(uname -r)"
KMAJ="$(echo "$KVER" | cut -d. -f1)"
KMIN="$(echo "$KVER" | cut -d. -f2)"
if [[ "$KMAJ" -lt 6 || ( "$KMAJ" -eq 6 && "$KMIN" -lt 11 ) ]]; then
  warn "Kernel ${KVER} is too old — R9700 (gfx1201) requires ≥ 6.11"
  warn "  sudo apt install linux-generic-hwe-24.04 && sudo reboot"
else
  ok "Kernel ${KVER} (≥ 6.11)"
fi

# ── 2. gfx1201 firmware ───────────────────────────────────────────────
say "gfx1201 firmware"
FW_DST="/lib/firmware/amdgpu"
if ls "${FW_DST}/gc_12_0_1_"*.bin* >/dev/null 2>&1; then
  ok "firmware already present"
elif [[ -d "$REPO_ROOT/firmware/amdgpu" ]]; then
  sudo mkdir -p "$FW_DST"
  sudo cp "$REPO_ROOT/firmware/amdgpu/"* "$FW_DST/"
  sudo update-initramfs -u -k "$(uname -r)" >/dev/null 2>&1 || true
  ok "firmware installed"
  warn "Reboot required before GPU will initialize: sudo reboot"
else
  warn "firmware/ directory missing — GPU may not initialize"
fi

# ── 3. Host packages ──────────────────────────────────────────────────
say "Installing packages"
PKGS=(
  # burn-in tools
  fio stress-ng memtester pciutils smartmontools nvme-cli lm-sensors ipmitool dmidecode jq
  # build + config
  build-essential python3 python3-yaml python3-pip
  # Vulkan GPU burn
  libvulkan-dev glslang-tools mesa-vulkan-drivers
)
sudo apt-get update -qq
failed=()
for pkg in "${PKGS[@]}"; do
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1; then
    ok "$pkg"
  else
    failed+=("$pkg"); warn "$pkg — install failed"
  fi
done
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mcelog >/dev/null 2>&1 \
  && ok "mcelog (optional)" || warn "mcelog unavailable — MCE falls back to dmesg"
(( ${#failed[@]} == 0 )) && ok "all packages installed" \
  || warn "failed: ${failed[*]}"

# ── 4. Build vk_burn ─────────────────────────────────────────────────
say "Building vk_burn"
mkdir -p "$REPO_ROOT/build"
SPV="$REPO_ROOT/build/vk_burn.comp.spv"
glslangValidator -V "$REPO_ROOT/src/vk_burn.comp" -o "$SPV" 2>/dev/null \
  && ok "shader compiled" || fail "shader compile failed"
[[ -f "$SPV" ]] && \
  g++ -O2 "$REPO_ROOT/src/vk_burn.cpp" -o "$REPO_ROOT/build/vk_burn" -lvulkan 2>/dev/null \
    && ok "vk_burn built" || fail "vk_burn build failed"

# ── 5. GUI dependencies ───────────────────────────────────────────────
say "GUI dependencies"
pip3 install PyQt6 pyqtgraph --quiet --break-system-packages 2>/dev/null \
  && ok "PyQt6 + pyqtgraph" || warn "pip install failed — GUI may not work"

# ── 6. LLM bench (optional) ──────────────────────────────────────────
if (( WITH_LLM )); then
  say "Building llama.cpp (Vulkan backend)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cmake git curl ca-certificates glslc spirv-headers >/dev/null 2>&1
  LLAMA_DIR="$REPO_ROOT/third_party/llama.cpp"
  [[ ! -d "$LLAMA_DIR" ]] && \
    git clone --depth 1 https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR" 2>/dev/null \
      && ok "cloned llama.cpp" || fail "git clone failed"
  [[ -d "$LLAMA_DIR" ]] && \
    cmake -B "$LLAMA_DIR/build_vk" -S "$LLAMA_DIR" -DGGML_VULKAN=ON -DGGML_HIP=OFF \
      -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1 && \
    cmake --build "$LLAMA_DIR/build_vk" --target llama-cli -j"$(nproc)" >/dev/null 2>&1 && \
    cp "$LLAMA_DIR/build_vk/bin/llama-cli" "$REPO_ROOT/build/llama-cli" \
      && ok "llama-cli built" || fail "llama.cpp build failed"
  ls "$REPO_ROOT/models/"*.gguf >/dev/null 2>&1 \
    && ok "model found in models/" \
    || warn "no .gguf model in models/ — place one there before running LLM bench"
else
  say "LLM bench skipped (use --with-llm to enable)"
fi

# ── 7. Sanity check ───────────────────────────────────────────────────
say "Sanity check"
n=0
for d in /sys/class/hwmon/hwmon*; do
  [[ "$(cat "$d/name" 2>/dev/null)" == "amdgpu" ]] && n=$((n+1))
done
ok "sysfs sees $n amdgpu device(s)"
[[ -x "$REPO_ROOT/build/vk_burn" ]] && ok "vk_burn ready" || fail "vk_burn not built"

chmod +x "$REPO_ROOT"/*.sh "$REPO_ROOT"/stress/*.sh 2>/dev/null || true

say "Done"
cat <<EOF

  Quick start:
    sudo ./run_acceptance.sh --serial SN001 --duration 30m
    sudo -E python3 gui/main.py
EOF
