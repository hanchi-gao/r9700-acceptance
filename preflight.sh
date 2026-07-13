#!/usr/bin/env bash
# preflight.sh — Stage 1: go/no-go gate.
# Block known environment problems that would make burn-in a waste of time.
# No ROCm required — uses Vulkan for GPU burn, sysfs for monitoring.

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

hdr "Stage 1: preflight (go/no-go)"

# --- Kernel ----------------------------------------------------------------
min_kver="$(cfg kernel.min_version)"; min_kver="${min_kver:-6.11}"
kver="$(uname -r | grep -oE '^[0-9]+\.[0-9]+' )"
if [[ -z "$kver" ]]; then
  fail "kernel version" "could not parse $(uname -r)"
elif awk -v a="$kver" -v m="$min_kver" 'BEGIN{split(a,x,".");split(m,y,".");exit !(x[1]>y[1]||(x[1]==y[1]&&x[2]>=y[2]))}'; then
  pass "kernel >= $min_kver" "running $(uname -r)"
else
  fail "kernel >= $min_kver" "running $(uname -r) — gfx1201 PCI id $GPU_PCI_ID will NOT enumerate on <6.11"
fi

# --- GPU driver (amdgpu kernel module) -------------------------------------
n_amdgpu=0
for d in /sys/class/hwmon/hwmon*; do
  [[ "$(cat "$d/name" 2>/dev/null)" == "amdgpu" ]] && n_amdgpu=$((n_amdgpu+1))
done
if (( n_amdgpu > 0 )); then
  pass "amdgpu driver" "$n_amdgpu GPU(s) detected via sysfs"
else
  fail "amdgpu driver" "no amdgpu hwmon found — GPU driver not loaded"
fi

# --- Vulkan (GPU burn) -----------------------------------------------------
if [[ -x "$REPO_ROOT/build/vk_burn" ]]; then
  pass "vk_burn ready" "Vulkan GPU burn binary present"
else
  if command -v g++ >/dev/null && command -v glslangValidator >/dev/null; then
    skipw "vk_burn" "not built yet — will build on first run. Or run ./deploy.sh"
  else
    fail "vk_burn build tools" "need g++ + glslangValidator. FIX: sudo apt install build-essential libvulkan-dev glslang-tools && ./deploy.sh"
  fi
fi

# --- Required host tools ----------------------------------------------------
declare -A TOOL_FIX=(
  [lspci]="pciutils"     [fio]="fio"            [stress-ng]="stress-ng"
  [memtester]="memtester" [smartctl]="smartmontools" [nvme]="nvme-cli"
  [sensors]="lm-sensors"  [dmidecode]="dmidecode"   [python3]="python3"
)
missing=()
for t in lspci fio stress-ng memtester smartctl nvme sensors dmidecode python3; do
  if command -v "$t" >/dev/null 2>&1; then :; else missing+=("$t(${TOOL_FIX[$t]})"); fi
done
if (( ${#missing[@]} == 0 )); then
  pass "required host tools present"
else
  fail "required host tools present" "missing: ${missing[*]}. FIX: run ./deploy.sh"
fi

# python3 yaml module (config reader depends on it)
if python3 -c 'import yaml' 2>/dev/null; then
  pass "python3 PyYAML present"
else
  fail "python3 PyYAML present" "FIX: sudo apt install python3-yaml (or run ./deploy.sh)"
fi

# Warn-only tools
for t in ipmitool mcelog; do
  command -v "$t" >/dev/null 2>&1 || skipw "optional tool: $t" "not installed (warn-only). MCE falls back to dmesg"
done

# ROCm (optional — only needed for LLM bench)
if command -v rocm-smi >/dev/null 2>&1; then
  rocm_ver=""
  [[ -r /opt/rocm/.info/version ]] && rocm_ver="$(grep -oE '^[0-9]+\.[0-9]+' /opt/rocm/.info/version | head -1)"
  pass "ROCm (optional)" "found ${rocm_ver:-unknown} — LLM bench available"
else
  skipw "ROCm (optional)" "not installed — LLM bench will not be available (burn-in works without it)"
fi

# host sysctl
nb="$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)"
if [[ "$nb" == "0" ]]; then
  pass "kernel.numa_balancing=0"
else
  skipw "kernel.numa_balancing=0" "currently '$nb'. FIX: sudo sysctl -w kernel.numa_balancing=0"
fi

# --- Verdict ---------------------------------------------------------------
n_fail="$(count_fails)"
hdr "preflight result: $([[ $n_fail -eq 0 ]] && echo "${C_GRN}GO${C_RST}" || echo "${C_RED}NO-GO ($n_fail failed)${C_RST}")"
exit $(( n_fail > 0 ? 1 : 0 ))
