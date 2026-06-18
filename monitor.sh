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
HEADER="timestamp,gpu_id,bdf,junction_temp,memory_temp,edge_temp,power_draw_w,vram_used_mb,vram_total_mb,gpu_clock_mhz,mem_clock_mhz,throttle_status,ecc_total,nvme_temp,fan_rpm,chassis_power_w"
[[ -f "$CSV" ]] || echo "$HEADER" > "$CSV"

SUDO=""; sudo -n true 2>/dev/null && SUDO="sudo -n"

# dmesg cursor so we only report NEW lines each scan.
dmesg_since=0
scan_events() {
  local now line
  now="$(date '+%Y-%m-%dT%H:%M:%S')"
  while IFS= read -r line; do
    case "$line" in
      *AER*|*"Machine check"*|*"mce:"*|*"amdgpu"*"reset"*|*"ring "*"timeout"*|*"GPU reset"*)
        printf '%s\t%s\n' "$now" "$line" >> "$EVENTS" ;;
    esac
  done < <(${SUDO} dmesg --notime 2>/dev/null | tail -n +$((dmesg_since+1)))
  dmesg_since="$(${SUDO} dmesg 2>/dev/null | wc -l)"
}

# Pull one metrics snapshot for all GPUs into the CSV.
poll_gpus() {
  local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S')"
  python3 - "$ts" <<'PY' >> "$CSV"
import sys, json, subprocess
ts = sys.argv[1]
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
           "N/A","N/A","N/A",num(fanr),"N/A"]
    print(",".join(row))
PY
  # NVMe temp (first drive) — patch the last rows' nvme_temp column best-effort
  local nt
  nt="$(${SUDO} smartctl -A /dev/nvme0n1 2>/dev/null | awk '/Temperature:/{print $2; exit}')"
  [[ -n "$nt" ]] && printf '%s\tnvme0n1_temp=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$nt" >> "$RESULTS_DIR/nvme_temp.log"
}

info "monitor: polling every ${POLL_SECS}s -> $CSV  (events -> $EVENTS)"
start="$(date +%s)"
trap 'info "monitor: stopping"; exit 0' INT TERM
while :; do
  poll_gpus
  scan_events
  if (( DURATION > 0 )) && (( $(date +%s) - start >= DURATION )); then break; fi
  sleep "$POLL_SECS"
done
