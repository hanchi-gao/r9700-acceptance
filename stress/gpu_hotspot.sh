#!/usr/bin/env bash
# stress/gpu_hotspot.sh — drive max junction temp on every GPU in parallel.
# Tries ROCm/gpu-burn first; falls back to compiling src/gpu_burn.hip.
# One independent process per GPU (HIP_VISIBLE_DEVICES) — no TP/sync bubbles,
# so compute stays continuous and junction temp peaks. (plan §6)
#
# Usage: ./stress/gpu_hotspot.sh [--duration SECONDS]
# Pass/fail (junction temp vs threshold) is judged later from telemetry.csv;
# this script's job is to APPLY the load and exit cleanly.

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DURATION=120
[[ "${1:-}" == "--duration" ]] && DURATION="${2:-120}"

BUILD="$REPO_ROOT/build"; mkdir -p "$BUILD"
ARCH="$(rocminfo 2>/dev/null | grep -oE 'gfx[0-9a-f]+' | head -1)"; ARCH="${ARCH:-gfx1201}"

trap cleanup_tracked EXIT INT TERM

BURN_BIN=""
# 1) Try upstream ROCm/gpu-burn
if [[ ! -x "$BUILD/gpu-burn/gpu_burn" ]]; then
  if git clone --depth 1 https://github.com/ROCm/gpu-burn "$BUILD/gpu-burn" >/dev/null 2>&1; then
    if make -C "$BUILD/gpu-burn" >/dev/null 2>&1 && [[ -x "$BUILD/gpu-burn/gpu_burn" ]]; then
      BURN_BIN="$BUILD/gpu-burn/gpu_burn"
    fi
  fi
else
  BURN_BIN="$BUILD/gpu-burn/gpu_burn"
fi

# 2) Fallback: compile our HIP kernel
if [[ -z "$BURN_BIN" ]]; then
  warn "ROCm/gpu-burn unavailable; falling back to src/gpu_burn.hip"
  if hipcc --offload-arch="$ARCH" -O3 "$REPO_ROOT/src/gpu_burn.hip" -o "$BUILD/gpu_burn" 2>"$RESULTS_DIR/gpu_burn_build.log"; then
    BURN_BIN="$BUILD/gpu_burn"
  else
    die "could not build any gpu-burn (see $RESULTS_DIR/gpu_burn_build.log)"
  fi
fi
info "gpu_hotspot: using $BURN_BIN (arch=$ARCH) for ${DURATION}s on all GPUs"

n="$(gpu_count)"
for id in $(seq 0 $((n-1))); do
  if [[ "$BURN_BIN" == *gpu-burn/gpu_burn ]]; then
    HIP_VISIBLE_DEVICES="$id" "$BURN_BIN" "$DURATION" >"$RESULTS_DIR/hotspot_gpu${id}.log" 2>&1 &
  else
    HIP_VISIBLE_DEVICES="$id" "$BURN_BIN" "$DURATION" >"$RESULTS_DIR/hotspot_gpu${id}.log" 2>&1 &
  fi
  track_pid "$!"
  info "  launched gpu_burn on GPU$id (pid $!)"
done

wait
info "gpu_hotspot: all GPU burn processes finished"
