#!/usr/bin/env bash
# stress/cpu_mem.sh — CPU + system RAM burn across ALL cores / NUMA nodes.
# GPU stress can't touch most system RAM; bad DIMMs only surface here (plan §6).
#
# Usage: ./stress/cpu_mem.sh [--duration SECONDS]

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DEADLINE="$(resolve_deadline "$@")"
DURATION=$(( DEADLINE - $(date +%s) )); (( DURATION < 1 )) && DURATION=1

# Guard: a missing stress-ng must FAIL loudly, not silently pass (its
# "command not found" text wouldn't match the verify-error grep below).
if ! command -v stress-ng >/dev/null; then
  fail "cpu_mem" "stress-ng not installed — cannot stress CPU/RAM. FIX: ./deploy.sh"
  exit 1
fi

trap cleanup_tracked EXIT INT TERM

ncpu="$(nproc)"
if [[ "${BURNIN_MODE:-}" == "light" ]]; then
  ncpu=$(( ncpu / 2 )); (( ncpu < 1 )) && ncpu=1
fi
nnode="$(lscpu | awk -F: '/NUMA node\(s\)/{gsub(/ /,"",$2);print $2}')"; nnode="${nnode:-1}"
info "cpu_mem: ${ncpu} CPUs across ${nnode} NUMA node(s), ${DURATION}s (mode=${BURNIN_MODE:-full})"

# --- CPU: stress-ng all cores, with verification (catches compute faults) ---
stress-ng --cpu "$ncpu" --cpu-method all --verify \
          --metrics-brief --timeout "${DURATION}s" \
          > "$RESULTS_DIR/stressng_cpu.log" 2>&1 &
track_pid "$!"

# --- RAM: size the VM workload to ~80% of free RAM, spread over all cores ----
free_kb="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
vm_bytes_total=$(( free_kb * 1024 * 80 / 100 ))
vm_workers="$ncpu"
vm_each=$(( vm_bytes_total / vm_workers ))
info "cpu_mem: stress-ng --vm ${vm_workers} workers x $(( vm_each/1024/1024 ))MB (~80% of avail RAM)"
stress-ng --vm "$vm_workers" --vm-bytes "${vm_each}" --vm-method all --verify \
          --metrics-brief --timeout "${DURATION}s" \
          > "$RESULTS_DIR/stressng_vm.log" 2>&1 &
track_pid "$!"

# --- memtester: strict pattern coverage on a slice, BOUNDED to the deadline --
# memtester ignores any duration of its own — one "pass" runs ~20 patterns over
# the whole region and can take 10+ minutes on a large slice. So we cap the
# region small and wrap it in `timeout` (loops=0 => run continuously; timeout
# stops it cleanly at the deadline, exit 124, which is NOT a failure).
if command -v memtester >/dev/null && [[ "${BURNIN_MODE:-}" != "light" ]]; then
  mt_mb=$(( free_kb / 1024 / 8 ))    # ~12% of available
  (( mt_mb > 4096 )) && mt_mb=4096   # keep small enough to cycle patterns in-window
  (( mt_mb < 256 ))  && mt_mb=256
  info "cpu_mem: memtester ${mt_mb}MB, looping bounded to ${DURATION}s"
  timeout "${DURATION}s" memtester "${mt_mb}M" 0 > "$RESULTS_DIR/memtester.log" 2>&1 &
  track_pid "$!"
fi

wait

# --- Judge ----------------------------------------------------------------
# stress-ng prints a log LEVEL field: 'info:', 'fail:', 'error:'. A real failure
# is a 'fail:'/'error:' level line OR a non-zero "failed: N" summary. Do NOT just
# grep the word "fail" — the success summary line is "info: [pid] failed: 0".
if grep -qE 'stress-ng: (fail|error):' "$RESULTS_DIR/stressng_cpu.log" "$RESULTS_DIR/stressng_vm.log" 2>/dev/null \
   || grep -qE 'failed: [1-9]'        "$RESULTS_DIR/stressng_cpu.log" "$RESULTS_DIR/stressng_vm.log" 2>/dev/null; then
  fail "cpu_mem stress-ng verify" "verification errors found (see stressng_*.log)"
else
  pass "cpu_mem stress-ng verify" "no compute/memory verify errors (failed: 0)"
fi
if [[ -f "$RESULTS_DIR/memtester.log" ]]; then
  if grep -qF 'FAILURE' "$RESULTS_DIR/memtester.log"; then
    fail "memtester" "pattern failures (see memtester.log) — bad DIMM"
  else
    pass "memtester" "no pattern failures (bounded ${DURATION}s)"
  fi
fi
info "cpu_mem: done"
