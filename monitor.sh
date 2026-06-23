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

# Pull one metrics snapshot for all GPUs into the CSV.
poll_gpus() {
  local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S')"
  local cpu_temps nvme_t
  read -r cpu_tctl cpu_tccd1 <<< "$(read_cpu_temp)"
  nvme_t="$(read_nvme_temp)"
  python3 - "$ts" "$nvme_t" "$cpu_tctl" "$cpu_tccd1" <<'PY' >> "$CSV"
import sys, json, subprocess
ts, nvme_t, cpu_tctl, cpu_tccd1 = sys.argv[1:5]
def smi(*a):
    try: return json.loads(subprocess.run(["rocm-smi",*a,"--json"],capture_output=True,text=True).stdout)
    except Exception: return {}
def g(d,*keys):
    for k in keys:
        for kk,v in d.items():
            if kk.lower()==k.lower() or k.lower() in kk.lower():
                return v
    return "N/A"
bus  = smi("--showbus")
temp = smi("--showtemp")
pwr  = smi("--showpower")
mem  = smi("--showmeminfo","vram")
clk  = smi("--showclocks")
fan  = smi("--showfan")
cards = set(bus)|set(temp)|set(mem)
def num(x):
    try: return str(float(x))
    except Exception: return "N/A"
for card in sorted(cards, key=lambda c:int(''.join(ch for ch in c if ch.isdigit()) or 0)):
    gid = ''.join(ch for ch in card if ch.isdigit())
    bdf = g(bus.get(card,{}),"PCI Bus")
    t = temp.get(card,{})
    junction = g(t,"junction","Temperature (Sensor junction)")
    memt     = g(t,"memory","Temperature (Sensor memory)")
    edge     = g(t,"edge","Temperature (Sensor edge)")
    power    = g(pwr.get(card,{}),"Average Graphics Package Power","Current Socket Graphics Package Power","power")
    m = mem.get(card,{})
    used = g(m,"VRAM Total Used Memory (B)")
    tot  = g(m,"VRAM Total Memory (B)")
    try: used = str(round(float(used)/1048576))
    except Exception: used="N/A"
    try: tot = str(round(float(tot)/1048576))
    except Exception: tot="N/A"
    c = clk.get(card,{})
    sclk = g(c,"sclk clock speed","sclk")
    mclk = g(c,"mclk clock speed","mclk")
    fanr = g(fan.get(card,{}),"Fan speed (RPM)","fan")
    row = [ts,gid,str(bdf),num(junction),num(memt),num(edge),num(power),used,tot,
           ''.join(ch for ch in str(sclk) if ch.isdigit() or ch=='.') or "N/A",
           ''.join(ch for ch in str(mclk) if ch.isdigit() or ch=='.') or "N/A",
           "N/A","N/A",nvme_t,num(fanr),"N/A",cpu_tctl,cpu_tccd1]
    print(",".join(row))
PY
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
