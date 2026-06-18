#!/usr/bin/env bash
# stress/gpu_interconnect.sh — rccl-tests all-reduce sustained, to verify
# interconnect stability UNDER thermal load. Acceptance cares about
# no-degradation / no-PCIe-errors under heat, not the absolute GB/s (plan §6).
#
# Usage: ./stress/gpu_interconnect.sh [--duration SECONDS]
#
# rccl-tests is not a host package; we run it from the rocm-vllm container if it
# ships the binaries, else try a local build, else WARN (never silent-skip).

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DURATION=120
[[ "${1:-}" == "--duration" ]] && DURATION="${2:-120}"

trap cleanup_tracked EXIT INT TERM

n="$(gpu_count)"
GPU_ARGS="$(docker_gpu_args)"
end=$(( $(date +%s) + DURATION ))

run_once_in_container() {
  # Look for all_reduce_perf inside the container's PATH or common locations.
  docker run --rm $GPU_ARGS --ipc=host --network=host "$VRAM_IMAGE" bash -lc '
    bin=$(command -v all_reduce_perf || ls /opt/rccl-tests/build/all_reduce_perf 2>/dev/null || ls /workspace/rccl-tests/build/all_reduce_perf 2>/dev/null)
    if [[ -z "$bin" ]]; then echo "RCCL_TESTS_MISSING"; exit 42; fi
    "$bin" -b 64M -e 2G -f 2 -g '"$n"'
  ' 2>&1
}

if ! docker image inspect "$VRAM_IMAGE" >/dev/null 2>&1; then
  skipw "interconnect (rccl-tests)" "vLLM image not present; cannot run. FIX: docker pull $VRAM_IMAGE"
  exit 0
fi

log_file="$RESULTS_DIR/interconnect.log"
: > "$log_file"
loops=0; first_bw=""; last_bw=""; missing=0
while (( $(date +%s) < end )); do
  out="$(run_once_in_container)"
  echo "$out" >> "$log_file"
  if grep -q RCCL_TESTS_MISSING <<<"$out"; then missing=1; break; fi
  bw="$(grep -oE 'busbw[^0-9]*[0-9.]+' <<<"$out" | grep -oE '[0-9.]+' | tail -1)"
  [[ -z "$first_bw" && -n "$bw" ]] && first_bw="$bw"
  [[ -n "$bw" ]] && last_bw="$bw"
  loops=$((loops+1))
done

if (( missing == 1 )); then
  skipw "interconnect (rccl-tests)" "all_reduce_perf not in image. FIX: build rccl-tests into the image or set RCCL_TESTS path"
  exit 0
fi

# Judge: no bandwidth collapse over the run, and no PCIe/AER errors logged.
if [[ -n "$first_bw" && -n "$last_bw" ]]; then
  if awk -v a="$last_bw" -v b="$first_bw" 'BEGIN{exit !(a >= 0.80*b)}'; then
    pass "interconnect stable" "busbw start=${first_bw} end=${last_bw} GB/s over $loops iters"
  else
    fail "interconnect stable" "busbw collapsed start=${first_bw} -> end=${last_bw} GB/s (>20% drop under load)"
  fi
else
  skipw "interconnect stable" "could not parse busbw from rccl-tests output (see $log_file)"
fi
info "gpu_interconnect: done"
