#!/usr/bin/env bash
# stress/combined.sh — THE burn-in stage: every subsystem loaded simultaneously,
# sharing one deadline. This is the worst case an acceptance run cares about:
#   - GPU:       gpu_vram (rocBLAS GEMM) -> fills ~29.5GB VRAM, ~300W, hot HBM
#   - CPU + RAM: cpu_mem (stress-ng across all cores/channels)
#   - SSD:       ssd (fio, write-guarded)
# Running them together validates PSU peak (4 cards + CPU full draw) and worst-
# case chassis heat soak, while VRAM is genuinely occupied. Each child writes its
# own PASS/FAIL rows + logs; the monitor records temps/power/events throughout.
#
# Usage: ./stress/combined.sh [--duration SECONDS | --deadline EPOCH] [--fio-target PATH]

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DEADLINE="$(resolve_deadline "$@")"
FIO_TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fio-target) FIO_TARGET="$2"; shift 2;;
    *) shift;;
  esac
done

trap cleanup_tracked EXIT INT TERM
HERE="$(dirname "$(readlink -f "$0")")"

info "combined burn-in until $(date -d "@$DEADLINE" '+%H:%M:%S'): GPU GEMM(VRAM) + stress-ng + fio"

# All subsystems at once, sharing the deadline. Each child records its own checks.
"$HERE/gpu_vram.sh"         --deadline "$DEADLINE" >"$RESULTS_DIR/combined_gpu.log" 2>&1 &
track_pid "$!"
"$HERE/cpu_mem.sh"          --deadline "$DEADLINE" >"$RESULTS_DIR/combined_cpu.log" 2>&1 &
track_pid "$!"
ssd_args=(--deadline "$DEADLINE" --skip-threshold); [[ -n "$FIO_TARGET" ]] && ssd_args+=(--target "$FIO_TARGET")
"$HERE/ssd.sh" "${ssd_args[@]}" >"$RESULTS_DIR/combined_ssd.log" 2>&1 &
track_pid "$!"

wait
info "combined: done — see telemetry.csv for peak power / any card power-drop / reset events"
