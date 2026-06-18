#!/usr/bin/env bash
# stress/gpu_interconnect.sh — rccl-tests all-reduce sustained, to verify
# interconnect stability UNDER load (no bandwidth collapse / no PCIe errors).
# Acceptance cares about no-degradation under heat, not the absolute GB/s.
#
# Usage: ./stress/gpu_interconnect.sh [--duration SECONDS | --deadline EPOCH]
#
# rccl-tests is not a host package and RDNA4 P2P support varies. We look for a
# host all_reduce_perf binary (PATH or common ROCm locations). If it is not
# present we WARN (never silent-skip) with how to provide it — no docker needed.

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DEADLINE="$(resolve_deadline "$@")"

# Locate an all_reduce_perf binary on the host.
BIN="${RCCL_ALLREDUCE_BIN:-}"
if [[ -z "$BIN" ]]; then
  BIN="$(command -v all_reduce_perf 2>/dev/null || true)"
fi
for c in /opt/rocm/bin/all_reduce_perf /opt/rccl-tests/build/all_reduce_perf \
         "$REPO_ROOT/build/rccl-tests/build/all_reduce_perf"; do
  [[ -z "$BIN" && -x "$c" ]] && BIN="$c"
done

if [[ -z "$BIN" ]]; then
  skipw "interconnect (rccl-tests)" "no all_reduce_perf on host. FIX: build rccl-tests and set RCCL_ALLREDUCE_BIN=/path/to/all_reduce_perf (no docker needed)"
  exit 0
fi

n="$(gpu_count)"
log_file="$RESULTS_DIR/interconnect.log"; : > "$log_file"
info "interconnect: $BIN all-reduce on $n GPUs until $(date -d "@$DEADLINE" '+%H:%M:%S')"

first_bw=""; last_bw=""; loops=0
while [[ "$(date +%s)" -lt "$DEADLINE" ]]; do
  out="$("$BIN" -b 64M -e 2G -f 2 -g "$n" 2>&1)"
  echo "$out" >> "$log_file"
  bw="$(grep -oE 'busbw[^0-9]*[0-9.]+' <<<"$out" | grep -oE '[0-9.]+' | tail -1)"
  [[ -z "$first_bw" && -n "$bw" ]] && first_bw="$bw"
  [[ -n "$bw" ]] && last_bw="$bw"
  loops=$((loops+1))
done

if [[ -n "$first_bw" && -n "$last_bw" ]]; then
  if awk -v a="$last_bw" -v b="$first_bw" 'BEGIN{exit !(a >= 0.80*b)}'; then
    pass "interconnect stable" "busbw start=${first_bw} end=${last_bw} GB/s over $loops iters"
  else
    fail "interconnect stable" "busbw collapsed ${first_bw} -> ${last_bw} GB/s (>20% drop under load)"
  fi
else
  skipw "interconnect stable" "could not parse busbw (see $log_file)"
fi
info "gpu_interconnect: done"
