#!/usr/bin/env bash
# stress/gpu_hotspot.sh — drive max JUNCTION temp on every GPU in parallel.
# Uses the self-contained on-device FMA kernel (src/gpu_burn.hip): proven to
# pull ~300W / ~95C junction on gfx1201, no rocBLAS / docker / network needed.
# One independent process per GPU (HIP_VISIBLE_DEVICES) — continuous compute,
# no sync bubbles, so junction peaks. Runs to a shared deadline.
#
# Usage: ./stress/gpu_hotspot.sh [--duration SECONDS | --deadline EPOCH]
# Pass/fail (junction temp vs threshold) is judged later from telemetry.csv.

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DEADLINE="$(resolve_deadline "$@")"
BURN="$REPO_ROOT/build/gpu_burn"

trap cleanup_tracked EXIT INT TERM

if ! build_hip "$REPO_ROOT/src/gpu_burn.hip" "$BURN"; then
  die "failed to build gpu_burn (FMA). See $RESULTS_DIR/build.log"
fi
info "gpu_hotspot: FMA junction burn on all GPUs until $(date -d "@$DEADLINE" '+%H:%M:%S') (arch=$GPU_ARCH)"

n="$(gpu_count)"
for id in $(seq 0 $((n-1))); do
  HIP_VISIBLE_DEVICES="$id" "$BURN" "$DEADLINE" >"$RESULTS_DIR/hotspot_hip${id}.log" 2>&1 &
  track_pid "$!"
  info "  launched FMA burn on HIP device $id (pid $!)"
done

wait
# Surface each card's BDF + result line (HIP index != rocm-smi index; trust BDF).
for id in $(seq 0 $((n-1))); do
  line="$(grep -h 'done bdf=' "$RESULTS_DIR/hotspot_hip${id}.log" 2>/dev/null | tail -1)"
  [[ -n "$line" ]] && info "  HIP$id -> $line"
done
info "gpu_hotspot: all FMA burn processes finished"
