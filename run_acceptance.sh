#!/usr/bin/env bash
# run_acceptance.sh — orchestrator. Fail fast, in order:
#   preflight -> inventory -> (abort if either fails) -> burn-in -> report.
# Produces a machine-readable report.json + operator report.txt + tarball.
#
# Usage:
#   ./run_acceptance.sh --serial SN123 [--config expected_config.yaml]
#        [--duration 30m] [--mode full|preflight|inventory|burnin]
#        [--fio-target PATH]
#
# Burn-in is a SINGLE combined stage: GPU GEMM(VRAM) + rccl + stress-ng + fio
# all at once for --duration. So --duration IS the burn-in length (e.g. 30m).
# The individual stress/*.sh scripts remain runnable standalone (e.g. gpu_hotspot
# for a max-junction FMA probe) but the orchestrator runs only combined.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

SERIAL=""; CONFIG="$REPO_ROOT/expected_config.yaml"; DURATION="30m"
MODE="full"; FIO_TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)     SERIAL="$2"; shift 2;;
    --config)     CONFIG="$2"; shift 2;;
    --duration)   DURATION="$2"; shift 2;;
    --mode)       MODE="$2"; shift 2;;
    --fio-target) FIO_TARGET="$2"; shift 2;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[[ -z "$SERIAL" ]] && { echo "ERROR: --serial is required" >&2; exit 2; }

# Normalise duration (e.g. 30m, 90s, 1h) -> seconds for the stress scripts.
dur_to_secs() {
  local d="$1"
  case "$d" in
    *h) echo $(( ${d%h} * 3600 ));;
    *m) echo $(( ${d%m} * 60 ));;
    *s) echo "${d%s}";;
    *)  echo "$d";;
  esac
}
DUR_S="$(dur_to_secs "$DURATION")"

export CONFIG_FILE="$CONFIG"
TS="$(date +%Y%m%d_%H%M%S)"
export RESULTS_DIR="$REPO_ROOT/results/${SERIAL}_${TS}"
mkdir -p "$RESULTS_DIR"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"
source "$REPO_ROOT/lib/report.sh"

echo "serial=$SERIAL" > "$RESULTS_DIR/run.meta"
echo "config=$CONFIG" >> "$RESULTS_DIR/run.meta"
echo "duration=$DURATION ($DUR_S s)" >> "$RESULTS_DIR/run.meta"
echo "mode=$MODE" >> "$RESULTS_DIR/run.meta"
echo "host=$(hostname)" >> "$RESULTS_DIR/run.meta"
echo "started=$(date -Is)" >> "$RESULTS_DIR/run.meta"

hdr "ACCEPTANCE RUN  serial=$SERIAL  mode=$MODE  duration=$DURATION"
info "results -> $RESULTS_DIR"

MON_PID=""
stop_monitor() { [[ -n "$MON_PID" ]] && kill "$MON_PID" 2>/dev/null; MON_PID=""; }
trap 'stop_monitor' EXIT INT TERM

abort_report() {  # write report then exit non-zero
  generate_report "REJECTED" "$1"
  die "ABORTED: $1"
}

# ---- Stage 1: preflight ---------------------------------------------------
if [[ "$MODE" == "full" || "$MODE" == "preflight" ]]; then
  if ! "$REPO_ROOT/preflight.sh"; then
    abort_report "preflight failed (environment not ready)"
  fi
  [[ "$MODE" == "preflight" ]] && { generate_report "SEE_CHECKS" "preflight-only run"; exit 0; }
fi

# ---- Stage 2: inventory (captures baselines) ------------------------------
if [[ "$MODE" == "full" || "$MODE" == "inventory" ]]; then
  if ! "$REPO_ROOT/inventory.sh"; then
    abort_report "inventory failed (assembly mismatch) — see checks above"
  fi
  [[ "$MODE" == "inventory" ]] && { generate_report "SEE_CHECKS" "inventory-only run"; exit 0; }
fi

# ---- Stage 3: burn-in -----------------------------------------------------
if [[ "$MODE" == "full" || "$MODE" == "burnin" ]]; then
  POLL_SECS="${POLL_SECS:-2}" "$REPO_ROOT/monitor.sh" &
  MON_PID="$!"
  info "monitor started (pid $MON_PID)"
  info "burn-in: combined (all subsystems at once) for ${DURATION}"

  # Single combined stage: GPU GEMM(VRAM) + rccl + stress-ng + fio simultaneously.
  hdr "burn-in: combined";  "$REPO_ROOT/stress/combined.sh" --duration "$DUR_S" \
      ${FIO_TARGET:+--fio-target "$FIO_TARGET"} || true

  stop_monitor
  "$REPO_ROOT/lib/postcheck.sh" || true   # AER/SMART/temp/throttle deltas vs baseline
fi

# ---- Report ---------------------------------------------------------------
nfail="$(count_fails)"
verdict=$([[ "$nfail" -eq 0 ]] && echo "ACCEPTED" || echo "REJECTED")
generate_report "$verdict" "$nfail check(s) failed"

hdr "FINAL: $([[ "$verdict" == ACCEPTED ]] && echo "${C_GRN}ACCEPTED${C_RST}" || echo "${C_RED}REJECTED${C_RST}")  ($nfail failed)"
info "report: $RESULTS_DIR/report.txt  +  report.json"
exit $(( nfail > 0 ? 1 : 0 ))
