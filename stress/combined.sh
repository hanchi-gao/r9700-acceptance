#!/usr/bin/env bash
# stress/combined.sh — GPU + CPU + SSD simultaneously.
# Purpose: PSU peak validation (4 cards + CPU full draw is worst case; a weak
# PSU shows as a transient reset or a card dropping power) plus worst-case
# chassis heat soak (plan §6).
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

info "combined: GPU hotspot + CPU/mem + SSD together until $(date -d "@$DEADLINE" '+%H:%M:%S') (PSU peak / heat soak)"

# All three subsystems at once, sharing one deadline. Each child writes its own
# logs + check rows.
"$HERE/gpu_hotspot.sh" --deadline "$DEADLINE" >"$RESULTS_DIR/combined_gpu.log" 2>&1 &
track_pid "$!"
"$HERE/cpu_mem.sh" --deadline "$DEADLINE" >"$RESULTS_DIR/combined_cpu.log" 2>&1 &
track_pid "$!"
ssd_args=(--deadline "$DEADLINE")
[[ -n "$FIO_TARGET" ]] && ssd_args+=(--target "$FIO_TARGET")
"$HERE/ssd.sh" "${ssd_args[@]}" >"$RESULTS_DIR/combined_ssd.log" 2>&1 &
track_pid "$!"

wait
info "combined: done — check telemetry.csv for peak power / any card power-drop / reset events"
