#!/usr/bin/env bash
# monitor.sh — background telemetry logger (plan §7).
# Polls every POLL_SECS and appends to $RESULTS_DIR/telemetry.csv, plus an
# events.log scanning dmesg for AER / MCE / GPU-reset / throttle conditions.
#
# Usage:  RESULTS_DIR=... ./monitor.sh &        # stop by killing the PID
#         ./monitor.sh --duration 1800          # or self-limit
# Unsupported fields are written as N/A rather than crashing.

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"

POLL_SECS="${POLL_SECS:-2}"
DURATION=0
[[ "${1:-}" == "--duration" ]] && DURATION="${2:-0}"

CSV="$RESULTS_DIR/telemetry.csv"
EVENTS="$RESULTS_DIR/events.log"
HEADER="timestamp,gpu_id,bdf,junction_temp,memory_temp,edge_temp,power_draw_w,vram_used_mb,vram_total_mb,gpu_clock_mhz,mem_clock_mhz,throttle_status,ecc_total,nvme_temp,fan_rpm,chassis_power_w,cpu_tctl,cpu_tccd1"
[[ -f "$CSV" ]] || echo "$HEADER" > "$CSV"

SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"

# dmesg cursor so we only report NEW lines each scan. Initialised to the current
# line count BELOW (before the poll loop) so boot history is the baseline and is
# NOT flagged — we only care about events that appear DURING burn-in.
dmesg_since=0
scan_events() {
  local now line
  now="$(date '+%Y-%m-%dT%H:%M:%S')"
  while IFS= read -r line; do
    case "$line" in
      # Match real PCIe AER errors ("pcieport ...: AER:" / "PCIe Bus Error"),
      # NOT the benign boot ACPI line "_OSC: ... [AER LTR DPC]".
      *"AER:"*|*"PCIe Bus Error"*|*"Machine check"*|*"mce:"*|*"amdgpu"*"reset"*|*"ring "*"timeout"*|*"GPU reset"*)
        printf '%s\t%s\n' "$now" "$line" >> "$EVENTS" ;;
    esac
  done < <(${SUDO} dmesg --notime 2>/dev/null | tail -n +$((dmesg_since+1)))
  dmesg_since="$(${SUDO} dmesg 2>/dev/null | wc -l)"
}

# Read CPU temp from k10temp hwmon (AMD). Returns "Tctl Tccd1" in °C.
read_cpu_temp() {
  local dir tctl="N/A" tccd1="N/A"
  for dir in /sys/class/hwmon/hwmon*; do
    [[ "$(cat "$dir/name" 2>/dev/null)" == "k10temp" ]] || continue
    local f label
    for f in "$dir"/temp*_input; do
      [[ -f "$f" ]] || continue
      label="$(cat "${f%_input}_label" 2>/dev/null)"
      case "$label" in
        Tctl)  tctl="$(awk '{printf "%.1f",$1/1000}' "$f")";;
        Tccd1) tccd1="$(awk '{printf "%.1f",$1/1000}' "$f")";;
      esac
    done
    break
  done
  echo "$tctl $tccd1"
}

# Read NVMe composite temp from hwmon (no root needed). Returns °C or N/A.
read_nvme_temp() {
  local dir
  for dir in /sys/class/hwmon/hwmon*; do
    [[ "$(cat "$dir/name" 2>/dev/null)" == "nvme" ]] || continue
    local label
    label="$(cat "$dir/temp1_label" 2>/dev/null)"
    if [[ "$label" == "Composite" && -f "$dir/temp1_input" ]]; then
      awk '{printf "%.1f",$1/1000}' "$dir/temp1_input"
      return
    fi
  done
  echo "N/A"
}

# Read one sysfs value, or echo N/A.
read_sysfs() { cat "$1" 2>/dev/null || echo "N/A"; }

# Pull one metrics snapshot for all GPUs into the CSV (sysfs only, no rocm-smi).
poll_gpus() {
  local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S')"
  local cpu_tctl cpu_tccd1 nvme_t
  read -r cpu_tctl cpu_tccd1 <<< "$(read_cpu_temp)"
  nvme_t="$(read_nvme_temp)"

  local gid=0
  local dir
  for dir in /sys/class/hwmon/hwmon*; do
    [[ "$(cat "$dir/name" 2>/dev/null)" == "amdgpu" ]] || continue
    local bdf dev_path
    dev_path="$(readlink -f "$dir/device" 2>/dev/null)"
    bdf="$(basename "$dev_path")"

    # Temps (millidegrees -> degrees)
    local junction="N/A" memt="N/A" edge="N/A"
    local f label
    for f in "$dir"/temp*_input; do
      [[ -f "$f" ]] || continue
      label="$(cat "${f%_input}_label" 2>/dev/null)"
      case "$label" in
        junction) junction="$(awk '{printf "%.1f",$1/1000}' "$f")";;
        mem)      memt="$(awk '{printf "%.1f",$1/1000}' "$f")";;
        edge)     edge="$(awk '{printf "%.1f",$1/1000}' "$f")";;
      esac
    done

    # Power (microwatts -> watts)
    local power="N/A"
    [[ -f "$dir/power1_average" ]] && power="$(awk '{printf "%.1f",$1/1000000}' "$dir/power1_average")"

    # Fan
    local fanr="N/A"
    [[ -f "$dir/fan1_input" ]] && fanr="$(cat "$dir/fan1_input")"

    # Clocks (Hz -> MHz)
    local sclk="N/A" mclk="N/A"
    [[ -f "$dir/freq1_input" ]] && sclk="$(awk '{printf "%d",$1/1000000}' "$dir/freq1_input")"
    [[ -f "$dir/freq2_input" ]] && mclk="$(awk '{printf "%d",$1/1000000}' "$dir/freq2_input")"

    # VRAM via drm (bytes -> MB)
    local vram_used="N/A" vram_total="N/A"
    local card_dev
    for card_dev in /sys/class/drm/card*/device; do
      [[ "$(readlink -f "$card_dev")" == "$dev_path" ]] || continue
      [[ -f "$card_dev/mem_info_vram_total" ]] && vram_total="$(awk '{printf "%d",$1/1048576}' "$card_dev/mem_info_vram_total")"
      [[ -f "$card_dev/mem_info_vram_used" ]]  && vram_used="$(awk '{printf "%d",$1/1048576}' "$card_dev/mem_info_vram_used")"
      break
    done

    echo "$ts,$gid,$bdf,$junction,$memt,$edge,$power,$vram_used,$vram_total,$sclk,$mclk,N/A,N/A,$nvme_t,$fanr,N/A,$cpu_tctl,$cpu_tccd1" >> "$CSV"
    gid=$((gid+1))
  done
}

info "monitor: polling every ${POLL_SECS}s -> $CSV  (events -> $EVENTS)"
start="$(date +%s)"
# Baseline the dmesg cursor to NOW so existing boot history isn't flagged;
# only lines that appear during burn-in are recorded as events.
dmesg_since="$(${SUDO} dmesg 2>/dev/null | wc -l)"
trap 'info "monitor: stopping"; exit 0' INT TERM
while :; do
  poll_gpus
  scan_events
  if (( DURATION > 0 )) && (( $(date +%s) - start >= DURATION )); then break; fi
  sleep "$POLL_SECS"
done
