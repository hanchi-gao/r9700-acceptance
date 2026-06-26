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
# Usage: ./stress/combined.sh [--duration SECONDS | --deadline EPOCH]
#        [--fio-target PATH] [--components COMP,...]
#
# --components: comma-separated list of subsystems to run (gpu, cpu, ssd).
#   Default: "all" (same as gpu,cpu,ssd).

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DEADLINE="$(resolve_deadline "$@")"
FIO_TARGET=""
COMPONENTS="all"
GPU_IDS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fio-target)  FIO_TARGET="$2"; shift 2;;
    --components)  COMPONENTS="$2"; shift 2;;
    --gpu-ids)     GPU_IDS="$2";    shift 2;;
    *) shift;;
  esac
done

want_component() {
  [[ "$1" != "llm" && "$COMPONENTS" == "all" ]] || [[ ",$COMPONENTS," == *",$1,"* ]]
}

trap cleanup_tracked EXIT INT TERM
HERE="$(dirname "$(readlink -f "$0")")"

selected=""
want_component gpu && selected="${selected:+$selected + }GPU GEMM(VRAM)"
want_component cpu && selected="${selected:+$selected + }stress-ng"
want_component ssd && selected="${selected:+$selected + }fio"
info "combined burn-in until $(date -d "@$DEADLINE" '+%H:%M:%S'): $selected"

if want_component gpu; then
  gpu_args=(--deadline "$DEADLINE")
  [[ -n "$GPU_IDS" ]] && gpu_args+=(--gpus "$GPU_IDS")
  "$HERE/gpu_vram.sh" "${gpu_args[@]}" >"$RESULTS_DIR/combined_gpu.log" 2>&1 &
  track_pid "$!"
fi
if want_component cpu; then
  "$HERE/cpu_mem.sh" --deadline "$DEADLINE" >"$RESULTS_DIR/combined_cpu.log" 2>&1 &
  track_pid "$!"
fi
if want_component ssd; then
  ssd_args=(--deadline "$DEADLINE" --skip-threshold); [[ -n "$FIO_TARGET" ]] && ssd_args+=(--target "$FIO_TARGET")
  "$HERE/ssd.sh" "${ssd_args[@]}" >"$RESULTS_DIR/combined_ssd.log" 2>&1 &
  track_pid "$!"
fi

wait

if want_component llm; then
  if [[ -x "$REPO_ROOT/build/llama-cli" ]]; then
    info "combined: running LLM bench (sequential, after burn-in)"
    "$HERE/llm_bench.sh" >"$RESULTS_DIR/combined_llm.log" 2>&1 || true
  else
    info "combined: llm requested but llama-cli not found — skipping"
  fi
fi
info "combined: done — see telemetry.csv for peak power / any card power-drop / reset events"
