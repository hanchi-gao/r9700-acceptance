#!/usr/bin/env bash
# stress/gpu_vram.sh — fill VRAM + drive HBM/memory temp on every GPU in parallel.
# Uses the self-contained rocBLAS GEMM kernel (src/gemm_burn.hip): proven to
# occupy ~29.5GB VRAM, pull ~300W and push memory temp to ~86C on gfx1201 — no
# docker / vLLM / network needed. One process per GPU, runs to a shared deadline.
#
# Usage: ./stress/gpu_vram.sh [--duration SECONDS | --deadline EPOCH]
# Every healthy card must fill ~VRAM_BURN_PCT of its VRAM (judged from
# telemetry.csv vram_used + memory temp); a short/faulty card shows up here too.

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DEADLINE="$(resolve_deadline "$@")"
PCT="$(cfg gpu.vram_burn_pct)"; PCT="${PCT:-90}"
BURN="$REPO_ROOT/build/gemm_burn"

trap cleanup_tracked EXIT INT TERM

if ! build_hip "$REPO_ROOT/src/gemm_burn.hip" "$BURN" -lrocblas; then
  die "failed to build gemm_burn (needs rocBLAS: librocblas + rocblas.h). See $RESULTS_DIR/build.log"
fi
info "gpu_vram: GEMM VRAM/memory burn (fill ${PCT}%) on all GPUs until $(date -d "@$DEADLINE" '+%H:%M:%S')"

n="$(gpu_count)"
rc=0
for id in $(seq 0 $((n-1))); do
  HIP_VISIBLE_DEVICES="$id" "$BURN" "$DEADLINE" "$PCT" >"$RESULTS_DIR/vram_hip${id}.log" 2>&1 &
  track_pid "$!"
  info "  launched GEMM VRAM burn on HIP device $id (pid $!)"
done

# Collect per-process exit codes (a HIP/alloc failure on a bad card => FAIL).
for id in $(seq 0 $((n-1))); do
  if wait "%$((id+1))" 2>/dev/null; then :; fi
done
wait
for id in $(seq 0 $((n-1))); do
  log="$RESULTS_DIR/vram_hip${id}.log"
  alloc="$(grep -h 'resident VRAM' "$log" 2>/dev/null | tail -1)"
  done_line="$(grep -h 'done bdf=' "$log" 2>/dev/null | tail -1)"
  bdf="$(grep -hoE 'bdf=[0-9a-f:.]+' "$log" 2>/dev/null | head -1 | cut -d= -f2)"
  if [[ -n "$done_line" ]]; then
    pass "VRAM burn ${bdf:-HIP$id}" "${alloc#*bdf=* }"
  else
    fail "VRAM burn ${bdf:-HIP$id}" "did not complete — see $(basename "$log")"
    rc=1
  fi
done
info "gpu_vram: all GEMM VRAM burn processes finished"
exit $rc
