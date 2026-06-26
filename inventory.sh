#!/usr/bin/env bash
# inventory.sh — Stage 2: enumerate hardware and compare to expected_config.yaml.
# Any mismatch -> FAIL with the specific item + BDF. Also captures the
# pre-burn-in baselines (AER, NVMe SMART) that monitor.sh deltas against later.
#
# Some checks need root (lspci -vvv LnkSta, dmidecode, smartctl). When sudo is
# not available passwordless, those degrade to WARN (never a silent skip).

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

BASELINE_DIR="$RESULTS_DIR/baseline"
mkdir -p "$BASELINE_DIR"

# Can we elevate without a password prompt?
SUDO=""
if sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi

hdr "Stage 2: inventory (enumerate + compare)"

# --- GPU count -------------------------------------------------------------
exp_count="$(cfg gpu.count)"
act_count="$(gpu_count)"
assert_eq "GPU count" "$exp_count" "$act_count"

# --- Per-card VRAM (bytes) + cross-card consistency ------------------------
# Read VRAM from sysfs (no rocm-smi needed).
vram_min="$(cfg gpu.vram_bytes_min)"; vram_min="${vram_min:-33500000000}"
spread_max="$(cfg gpu.vram_spread_max_frac)"; spread_max="${spread_max:-0.02}"

mapfile -t VRAM_ROWS < <(
  exp_pci_id_lower="${GPU_PCI_ID,,}"  # e.g. "1002:7551"
  for card_dev in /sys/class/drm/card*/device; do
    driver="$(basename "$(readlink "$card_dev/driver" 2>/dev/null)")"
    [[ "$driver" == "amdgpu" ]] || continue
    # Filter by PCI ID — skip iGPU / BMC graphics / any non-target card
    vendor="$(cat "$card_dev/vendor" 2>/dev/null | sed 's/0x//')"
    device="$(cat "$card_dev/device" 2>/dev/null | sed 's/0x//')"
    [[ "${vendor}:${device}" == "$exp_pci_id_lower" ]] || continue
    bdf="$(basename "$(readlink -f "$card_dev")")"
    bytes="$(cat "$card_dev/mem_info_vram_total" 2>/dev/null)"
    [[ -n "$bytes" ]] && printf '%s\t%s\n' "$bdf" "$bytes"
  done
)
if (( ${#VRAM_ROWS[@]} == 0 )); then
  fail "VRAM per card" "could not read VRAM info from sysfs"
else
  printf '%s\n' "${VRAM_ROWS[@]}" > "$BASELINE_DIR/vram_bytes.tsv"
  vmax=0; vmin=0; first=1
  for row in "${VRAM_ROWS[@]}"; do
    bdf="${row%%$'\t'*}"; bytes="${row##*$'\t'}"
    gib="$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1073741824}')"
    if awk -v b="$bytes" -v m="$vram_min" 'BEGIN{exit !(b+0>=m+0)}'; then
      pass "VRAM $bdf" "${gib} GiB (>= floor)"
    else
      fail "VRAM $bdf" "${gib} GiB — BELOW floor $(awk -v m="$vram_min" 'BEGIN{printf "%.2f", m/1073741824}') GiB. Short/faulty card — replace it."
    fi
    if (( first )); then vmax=$bytes; vmin=$bytes; first=0; else
      (( bytes > vmax )) && vmax=$bytes
      (( bytes < vmin )) && vmin=$bytes
    fi
  done
  # Cross-card spread
  if awk -v mx="$vmax" -v mn="$vmin" -v lim="$spread_max" 'BEGIN{exit !((mx-mn)/mx <= lim)}'; then
    pass "VRAM uniform across cards" "spread $(awk -v mx="$vmax" -v mn="$vmin" 'BEGIN{printf "%.2f%%",(mx-mn)/mx*100}')"
  else
    fail "VRAM uniform across cards" "spread $(awk -v mx="$vmax" -v mn="$vmin" 'BEGIN{printf "%.2f%%",(mx-mn)/mx*100}') > ${spread_max} — one card is the odd one out"
  fi
fi

# --- PCIe link width/speed per card (LnkSta) -------------------------------
exp_w="$(cfg gpu.pcie_link_width)"
exp_s="$(cfg gpu.pcie_link_speed)"
lnk_reader() { ${SUDO} lspci -vvv -s "$1" 2>/dev/null | grep -E 'LnkSta:'; }
for bdf in $(gpu_bdfs); do
  short="${bdf#0000:}"
  lnksta="$(lnk_reader "$short")"
  if [[ -z "$lnksta" ]]; then
    skipw "PCIe link $bdf" "LnkSta unreadable (needs root). FIX: run via sudo or 'sudo -v' first"
    continue
  fi
  width="$(grep -oE 'Width x[0-9]+' <<<"$lnksta" | grep -oE '[0-9]+' | head -1)"
  speed="$(grep -oE 'Speed [0-9.]+GT/s' <<<"$lnksta" | grep -oE '[0-9.]+GT/s' | head -1)"
  if [[ "$width" == "$exp_w" && "$speed" == "$exp_s" ]]; then
    pass "PCIe link $bdf" "x$width $speed"
  else
    fail "PCIe link $bdf" "negotiated x$width $speed, expected x$exp_w $exp_s — reseat card/riser (down-negotiation halves bandwidth)"
  fi
done

# --- PCIe AER baseline (recompared post-burn-in) ---------------------------
for bdf in $(gpu_bdfs); do
  c="$(${SUDO} cat "/sys/bus/pci/devices/$bdf/aer_dev_correctable" 2>/dev/null | awk 'NR==1{print $2}')"
  u="$(${SUDO} cat "/sys/bus/pci/devices/$bdf/aer_dev_nonfatal"   2>/dev/null | awk 'NR==1{print $2}')"
  printf '%s\tcorrectable\t%s\n' "$bdf" "${c:-NA}" >> "$BASELINE_DIR/aer.tsv"
  printf '%s\tnonfatal\t%s\n'    "$bdf" "${u:-NA}" >> "$BASELINE_DIR/aer.tsv"
done
[[ -s "$BASELINE_DIR/aer.tsv" ]] && info "AER baseline captured -> $BASELINE_DIR/aer.tsv" \
  || skipw "AER baseline" "aer_dev_* unreadable (kernel without AER sysfs or needs root)"

# --- BDF <-> NUMA mapping --------------------------------------------------
exp_numa_nodes="$(cfg cpu.numa_nodes)"; exp_numa_nodes="${exp_numa_nodes:-1}"
if [[ "$exp_numa_nodes" == "1" ]]; then
  pass "BDF<->NUMA" "single NUMA node — mapping check informational (auto-pass)"
else
  while IFS=$'\t' read -r ebdf enode; do
    [[ -z "$ebdf" ]] && continue
    anode="$(cat "/sys/bus/pci/devices/$ebdf/numa_node" 2>/dev/null)"
    assert_eq "NUMA $ebdf" "$enode" "${anode:-NA}"
  done < <(paste <(cfg_list gpu.topology bdf) <(cfg_list gpu.topology numa_node))
fi

# --- VRAM ECC consistency across cards (sysfs RAS) -------------------------
mapfile -t ECC_STATES < <(
  for card_dev in /sys/class/drm/card*/device; do
    driver="$(basename "$(readlink "$card_dev/driver" 2>/dev/null)")"
    [[ "$driver" == "amdgpu" ]] || continue
    ras="$(cat "$card_dev/ras/features" 2>/dev/null | grep -o 'umc:[a-z]*' | cut -d: -f2)"
    [[ -n "$ras" ]] && echo "$ras"
  done
)
if (( ${#ECC_STATES[@]} )); then
  if [[ "$(printf '%s\n' "${ECC_STATES[@]}" | sort -u | wc -l)" == "1" ]]; then
    pass "VRAM ECC consistent" "all cards ECC=${ECC_STATES[0]}"
  else
    uniq_states="$(printf '%s\n' "${ECC_STATES[@]}" | sort -u | tr '\n' ',' )"
    fail "VRAM ECC consistent" "cards differ: $uniq_states — make ECC mode uniform"
  fi
else
  if command -v rocm-smi >/dev/null 2>&1; then
    mapfile -t ECC_STATES < <(rocm-smi --showrasinfo all 2>/dev/null | awk '/UMC/{print $2}')
    if (( ${#ECC_STATES[@]} )); then
      if [[ "$(printf '%s\n' "${ECC_STATES[@]}" | sort -u | wc -l)" == "1" ]]; then
        pass "VRAM ECC consistent" "all cards UMC=${ECC_STATES[0]}"
      else
        fail "VRAM ECC consistent" "cards differ — make ECC mode uniform"
      fi
    else
      skipw "VRAM ECC consistent" "RAS info not available — could not verify ECC mode"
    fi
  else
    skipw "VRAM ECC consistent" "RAS sysfs not available, rocm-smi not installed — skipping ECC check"
  fi
fi

# --- DIMM count / total RAM ------------------------------------------------
exp_dimm="$(cfg memory.dimm_count)"; exp_dimm="${exp_dimm:-0}"
if [[ "$exp_dimm" != "0" ]]; then
  dimm="$(${SUDO} dmidecode -t memory 2>/dev/null | grep -c 'Size:.*[GM]B')"
  if [[ -z "$dimm" || "$dimm" == "0" ]]; then
    skipw "DIMM count" "dmidecode unreadable (needs root). FIX: run via sudo"
  else
    assert_ge "DIMM count" "$exp_dimm" "$dimm"
  fi
fi
exp_ram="$(cfg memory.total_gb_min)"; exp_ram="${exp_ram:-0}"
# Prefer dmidecode (sums physical DIMMs, unaffected by iGPU UMA reservation).
# Fall back to /proc/meminfo when no root.
ram_gb=""
if [[ -n "$SUDO" ]]; then
  ram_gb="$(${SUDO} dmidecode -t memory 2>/dev/null | awk '
    /^\s+Size:/ && $2+0 > 0 {
      if ($3 == "GB") total += $2
      else if ($3 == "MB") total += $2/1024
      else if ($3 == "TB") total += $2*1024
    }
    END { if (total > 0) printf "%.0f", total }')"
fi
[[ -z "$ram_gb" || "$ram_gb" == "0" ]] && \
  ram_gb="$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)"
assert_ge "total RAM (GB)" "$exp_ram" "$ram_gb"

# --- DRAM type + per-DIMM capacity consistency --------------------------------
exp_dram_type="$(cfg memory.dram_type)"; exp_dram_type="${exp_dram_type:-}"
if [[ -n "$exp_dram_type" ]]; then
  if [[ -z "$SUDO" ]]; then
    skipw "DRAM type" "dmidecode needs root — run via sudo"
  else
    dram_info="$(${SUDO} dmidecode -t memory 2>/dev/null)"
    if [[ -z "$dram_info" ]]; then
      skipw "DRAM type" "dmidecode returned empty (needs root)"
    else
      types="$(grep '^\s*Type:' <<<"$dram_info" | grep -v 'Type Detail' | awk '{print $2}' | grep -v Unknown | sort -u)"
      if [[ -z "$types" ]]; then
        skipw "DRAM type" "dmidecode ran but all slots report Unknown (firmware limitation)"
      elif echo "$types" | grep -qi "$exp_dram_type"; then
        pass "DRAM type" "$exp_dram_type confirmed"
      else
        fail "DRAM type" "expected $exp_dram_type, found: $(echo "$types" | tr '\n' ' ')"
      fi
    fi

    # Per-DIMM capacity — all populated DIMMs must be the same size
    mapfile -t DIMM_SIZES < <(grep '^\s*Size:' <<<"$dram_info" | grep -v 'No Module' | awk '{print $2, $3}')
    if (( ${#DIMM_SIZES[@]} > 0 )); then
      uniq_sizes="$(printf '%s\n' "${DIMM_SIZES[@]}" | sort -u)"
      n_uniq="$(echo "$uniq_sizes" | wc -l)"
      if (( n_uniq == 1 )); then
        pass "DIMM capacity uniform" "${#DIMM_SIZES[@]} DIMMs × ${DIMM_SIZES[0]}"
      else
        fail "DIMM capacity uniform" "mixed sizes: $(echo $uniq_sizes | tr '\n' ', ') — all DIMMs should match"
      fi
    fi
  fi
fi

# --- NVMe count + SMART baseline -------------------------------------------
exp_nvme="$(cfg storage.nvme_count)"; exp_nvme="${exp_nvme:-1}"
act_nvme="$(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /^nvme/' | wc -l)"
assert_eq "NVMe count" "$exp_nvme" "$act_nvme"

for dev in $(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 ~ /^nvme/{print $1}'); do
  out="$(${SUDO} smartctl -a "/dev/$dev" 2>/dev/null)"
  [[ -z "$out" ]] && out="$(${SUDO} nvme smart-log "/dev/$dev" 2>/dev/null)"
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out" > "$BASELINE_DIR/smart_${dev}.txt"
    info "SMART baseline /dev/$dev -> $BASELINE_DIR/smart_${dev}.txt"
  else
    skipw "SMART baseline /dev/$dev" "smartctl/nvme needs root. FIX: run via sudo"
  fi
done

# --- Verdict ---------------------------------------------------------------
n_fail="$(count_fails)"
hdr "inventory result: $([[ $n_fail -eq 0 ]] && echo "${C_GRN}PASS${C_RST}" || echo "${C_RED}FAIL ($n_fail mismatches)${C_RST}")"
exit $(( n_fail > 0 ? 1 : 0 ))
