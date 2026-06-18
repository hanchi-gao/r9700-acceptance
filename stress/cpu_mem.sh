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
nnode="$(lscpu | awk -F: '/NUMA node\(s\)/{gsub(/ /,"",$2);print $2}')"; nnode="${nnode:-1}"
info "cpu_mem: ${ncpu} CPUs across ${nnode} NUMA node(s), ${DURATION}s"

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

# --- memtester on a smaller slice for stricter pattern coverage --------------
if command -v memtester >/dev/null; then
  mt_mb=$(( free_kb / 1024 / 4 ))   # 25% of available, single pass
  (( mt_mb > 8192 )) && mt_mb=8192  # cap so it finishes within the window
  info "cpu_mem: memtester ${mt_mb}MB 1 pass"
  memtester "${mt_mb}M" 1 > "$RESULTS_DIR/memtester.log" 2>&1 &
  track_pid "$!"
fi

wait

# --- Judge ----------------------------------------------------------------
if grep -qiE 'fail|error|incorrect' "$RESULTS_DIR/stressng_cpu.log" "$RESULTS_DIR/stressng_vm.log" 2>/dev/null; then
  fail "cpu_mem stress-ng verify" "verification errors found (see stressng_*.log)"
else
  pass "cpu_mem stress-ng verify" "no compute/memory verify errors"
fi
if [[ -f "$RESULTS_DIR/memtester.log" ]]; then
  if grep -qiE 'FAILURE|error' "$RESULTS_DIR/memtester.log"; then
    fail "memtester" "pattern failures (see memtester.log) — bad DIMM"
  else
    pass "memtester" "all patterns ok"
  fi
fi
info "cpu_mem: done"
