#!/usr/bin/env bash
# lib/postcheck.sh — post-burn-in delta checks vs Stage-2 baselines (plan §7).
# Re-capture AER + NVMe SMART, compare to baseline; any increment = FAIL.
# Also judge peak temps / throttle / MCE / GPU-reset from the burn-in telemetry.

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

BASELINE_DIR="$RESULTS_DIR/baseline"
SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"

hdr "post-burn-in delta checks"

# --- AER delta -------------------------------------------------------------
if [[ -f "$BASELINE_DIR/aer.tsv" ]]; then
  new_aer=0
  for bdf in $(gpu_bdfs); do
    for kind in correctable nonfatal; do
      file="/sys/bus/pci/devices/$bdf/aer_dev_${kind}"
      now="$(${SUDO} cat "$file" 2>/dev/null | awk 'NR==1{print $2}')"
      base="$(awk -v b="$bdf" -v k="$kind" '$1==b && $2==k{print $3}' "$BASELINE_DIR/aer.tsv")"
      [[ -z "$now" || -z "$base" || "$base" == "NA" ]] && continue
      if (( now > base )); then
        fail "AER $kind $bdf" "increased $base -> $now during burn-in"
        new_aer=1
      fi
    done
  done
  (( new_aer == 0 )) && pass "AER delta" "no new correctable/nonfatal errors"
fi

# --- NVMe SMART delta ------------------------------------------------------
for dev in $(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /^nvme/{print $1}'); do
  base="$BASELINE_DIR/smart_${dev}.txt"
  [[ -f "$base" ]] || continue
  now="$(${SUDO} smartctl -a "/dev/$dev" 2>/dev/null)"
  [[ -z "$now" ]] && { skipw "SMART delta /dev/$dev" "re-read failed (needs root)"; continue; }
  echo "$now" > "$RESULTS_DIR/smart_${dev}_post.txt"
  get() { grep -iE "$1" <<<"$2" | grep -oE '[0-9]+' | tail -1; }
  ok=1
  for field in "Reallocated" "Media and Data Integrity Errors|media_errors"; do
    b="$(get "$field" "$(cat "$base")")"; a="$(get "$field" "$now")"
    [[ -z "$b" || -z "$a" ]] && continue
    if (( a > b )); then fail "SMART /dev/$dev ($field)" "increased $b -> $a"; ok=0; fi
  done
  (( ok == 1 )) && pass "SMART delta /dev/$dev" "no new reallocated/media errors"
done

# --- Peak junction / memory temp from telemetry ----------------------------
tf="$RESULTS_DIR/telemetry.csv"
if [[ -f "$tf" ]]; then
  read -r pj pm <<<"$(python3 - "$tf" <<'PY'
import sys, csv
j=[];m=[]
with open(sys.argv[1]) as fh:
    for r in csv.DictReader(fh):
        for v,lst in ((r.get("junction_temp"),j),(r.get("memory_temp"),m)):
            try: lst.append(float(v))
            except: pass
print(round(max(j),1) if j else "NA", round(max(m),1) if m else "NA")
PY
)"
  if [[ "$pj" != "NA" ]]; then
    if awk -v p="$pj" -v f="$GPU_JUNCTION_FAIL_C" 'BEGIN{exit !(p<f)}'; then
      pass "peak junction temp" "${pj}C < ${GPU_JUNCTION_FAIL_C}C"
    else
      fail "peak junction temp" "${pj}C >= ${GPU_JUNCTION_FAIL_C}C limit"
    fi
  fi
  if [[ "$pm" != "NA" ]]; then
    if awk -v p="$pm" -v f="$GPU_MEMORY_FAIL_C" 'BEGIN{exit !(p<f)}'; then
      pass "peak memory temp" "${pm}C < ${GPU_MEMORY_FAIL_C}C"
    else
      fail "peak memory temp" "${pm}C >= ${GPU_MEMORY_FAIL_C}C limit"
    fi
  fi
fi

# --- MCE / GPU reset / AER from events.log ---------------------------------
ev="$RESULTS_DIR/events.log"
if [[ -f "$ev" && -s "$ev" ]]; then
  mce="$(grep -icE 'machine check|mce:' "$ev" || true)"
  rst="$(grep -icE 'amdgpu.*reset|gpu reset' "$ev" || true)"
  (( mce > MCE_COUNT_MAX )) && fail "MCE during burn-in" "$mce event(s)" || pass "MCE during burn-in" "none"
  (( rst > GPU_RESET_COUNT_MAX )) && fail "GPU reset during burn-in" "$rst event(s)" || pass "GPU reset during burn-in" "none"
else
  pass "MCE / GPU reset" "no events logged"
fi
