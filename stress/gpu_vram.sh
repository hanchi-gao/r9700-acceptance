#!/usr/bin/env bash
# stress/gpu_vram.sh — fill VRAM + drive memory temp on every GPU in parallel.
# Uses a Vulkan compute shader (src/vk_burn.cpp) — no ROCm, HIP, or rocBLAS
# needed. Only requires the amdgpu kernel module + Mesa Vulkan (Ubuntu default).
# One process per GPU, runs to a shared deadline.
#
# Usage: ./stress/gpu_vram.sh [--duration SECONDS | --deadline EPOCH]

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DEADLINE="$(resolve_deadline "$@")"
PCT="$(cfg gpu.vram_burn_pct)"; PCT="${PCT:-90}"
[[ "${BURNIN_MODE:-}" == "light" ]] && PCT=50
BURN="$REPO_ROOT/build/vk_burn"
GPU_IDS=""  # comma-separated indices to burn; empty = all
while [[ $# -gt 0 ]]; do
  case "$1" in --gpus) GPU_IDS="$2"; shift 2;; *) shift;; esac
done

trap cleanup_tracked EXIT INT TERM

# Build if needed (deploy.sh pre-builds, but handle first-run)
if [[ ! -x "$BURN" ]]; then
  info "gpu_vram: vk_burn not found, attempting build..."
  mkdir -p "$REPO_ROOT/build"
  SPV="$REPO_ROOT/build/vk_burn.comp.spv"
  if [[ ! -f "$SPV" ]]; then
    if command -v glslangValidator >/dev/null; then
      glslangValidator -V "$REPO_ROOT/src/vk_burn.comp" -o "$SPV" || die "shader compile failed"
    else
      die "glslangValidator not found — run: sudo apt install glslang-tools"
    fi
  fi
  g++ -O2 "$REPO_ROOT/src/vk_burn.cpp" -o "$BURN" -lvulkan 2>"$RESULTS_DIR/build.log" \
    || die "failed to build vk_burn — see build.log. Need: sudo apt install libvulkan-dev"
fi

# Count amdgpu Vulkan-capable GPUs via sysfs
n=0
declare -a GPU_BDFS=()
for d in /sys/class/hwmon/hwmon*; do
  [[ "$(cat "$d/name" 2>/dev/null)" == "amdgpu" ]] || continue
  bdf="$(basename "$(readlink -f "$d/device")")"
  GPU_BDFS+=("$bdf")
  n=$((n+1))
done
(( n == 0 )) && die "no amdgpu GPUs found in sysfs"

info "gpu_vram: Vulkan VRAM burn (fill ${PCT}%) on $n GPU(s) until $(date -d "@$DEADLINE" '+%H:%M:%S')"

# Copy SPIR-V next to binary so vk_burn can find it
cp -f "$REPO_ROOT/build/vk_burn.comp.spv" "$(dirname "$BURN")/vk_burn.comp.spv" 2>/dev/null || true

rc=0
for id in $(seq 0 $((n-1))); do
  # Skip if GPU_IDS is set and this id is not in the list
  if [[ -n "$GPU_IDS" && ",$GPU_IDS," != *",$id,"* ]]; then
    info "  skipping GPU $id [${GPU_BDFS[$id]}] (not selected)"
    continue
  fi
  "$BURN" "$DEADLINE" "$PCT" "$id" >"$RESULTS_DIR/vram_gpu${id}.log" 2>&1 &
  track_pid "$!"
  info "  launched Vulkan VRAM burn on GPU $id [${GPU_BDFS[$id]}] (pid $!)"
done

wait
for id in $(seq 0 $((n-1))); do
  log="$RESULTS_DIR/vram_gpu${id}.log"
  bdf="${GPU_BDFS[$id]}"
  slot="$(bdf_to_slot "$bdf")"
  label="$bdf [$slot]"
  done_line="$(grep -h 'done' "$log" 2>/dev/null | tail -1)"
  alloc_line="$(grep -h 'allocated' "$log" 2>/dev/null | tail -1)"
  if [[ -n "$done_line" ]]; then
    pass "VRAM burn $label" "${alloc_line:-completed}"
  else
    fail "VRAM burn $label" "did not complete — see $(basename "$log")"
    rc=1
  fi
done
info "gpu_vram: all Vulkan VRAM burn processes finished"
exit $rc
