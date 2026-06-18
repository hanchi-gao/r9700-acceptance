#!/usr/bin/env bash
# preflight.sh — Stage 1: go/no-go gate.
# Block known environment problems that would make burn-in a waste of time.
# Every check prints the PROBLEM and the FIX, then we exit non-zero on any fail.
#
# Assumes a freshly assembled machine that has ONLY git + ROCm + driver, then
# had deploy.sh run on it. If a host tool is missing, the fix is "run deploy.sh".

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
  fail "kernel >= $min_kver" "running $(uname -r) — gfx1201 PCI id $GPU_PCI_ID will NOT enumerate on <6.11. FIX: sudo apt install linux-generic-hwe-24.04 && reboot"
fi

# --- ROCm present + version ------------------------------------------------
min_rocm="$(cfg rocm.min_version)"; min_rocm="${min_rocm:-7.0}"
rocm_ver=""
[[ -r /opt/rocm/.info/version ]] && rocm_ver="$(grep -oE '^[0-9]+\.[0-9]+' /opt/rocm/.info/version | head -1)"
if [[ -z "$rocm_ver" ]] && command -v rocminfo >/dev/null; then
  rocm_ver="$(rocminfo 2>/dev/null | grep -oE 'ROCk.*' | head -1)"
fi
if [[ -z "$rocm_ver" ]]; then
  fail "ROCm installed" "no /opt/rocm/.info/version and rocminfo missing. FIX: run ./install_rocm.sh (then reboot)"
elif awk -v a="$rocm_ver" -v m="$min_rocm" 'BEGIN{split(a,x,".");split(m,y,".");exit !(x[1]>y[1]||(x[1]==y[1]&&x[2]>=y[2]))}'; then
  pass "ROCm >= $min_rocm" "found $rocm_ver"
else
  fail "ROCm >= $min_rocm" "found $rocm_ver. FIX: upgrade ROCm"
fi

# --- rocm-smi runs ---------------------------------------------------------
if command -v rocm-smi >/dev/null && rocm-smi --showid >/dev/null 2>&1; then
  pass "rocm-smi runs"
else
  fail "rocm-smi runs" "rocm-smi missing or errored. FIX: check ROCm install / driver"
fi

# --- Docker present + usable without sudo ----------------------------------
if ! command -v docker >/dev/null; then
  fail "docker present" "not installed. FIX: run ./deploy.sh"
elif docker info >/dev/null 2>&1; then
  pass "docker usable without sudo"
else
  fail "docker usable without sudo" "docker info failed (permission or daemon). FIX: sudo usermod -aG docker $USER && newgrp docker ; sudo systemctl enable --now docker"
fi

# --- Docker GPU access (best effort; needs the vLLM image present) ---------
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  if docker image inspect "$VRAM_IMAGE" >/dev/null 2>&1; then
    if docker run --rm $(docker_gpu_args) "$VRAM_IMAGE" rocm-smi --showid >/dev/null 2>&1; then
      pass "docker GPU access" "container sees GPUs (render=$(render_gid) video=$(video_gid))"
    else
      fail "docker GPU access" "container could not list GPUs. Check render/video GID passthrough. render=$(render_gid) video=$(video_gid)"
    fi
  else
    skipw "docker GPU access" "image not pulled yet; deferred. FIX: docker pull $VRAM_IMAGE (then re-run preflight)"
  fi
fi

# --- Required host tools ----------------------------------------------------
declare -A TOOL_FIX=(
  [lspci]="pciutils"     [fio]="fio"            [stress-ng]="stress-ng"
  [memtester]="memtester" [smartctl]="smartmontools" [nvme]="nvme-cli"
  [sensors]="lm-sensors"  [dmidecode]="dmidecode"    [hipcc]="rocm (hip-dev)"
  [git]="git"             [python3]="python3"
)
missing=()
for t in lspci fio stress-ng memtester smartctl nvme sensors dmidecode hipcc git python3; do
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
  fail "python3 PyYAML present" "FIX: sudo apt install python3-yaml  (or run ./deploy.sh)"
fi

# Warn-only tools
for t in ipmitool mcelog; do
  command -v "$t" >/dev/null 2>&1 || skipw "optional tool: $t" "not installed (warn-only). deploy.sh installs ipmitool; MCE falls back to dmesg"
done

# host sysctl for vLLM cross-NUMA KV faults
nb="$(cat /proc/sys/kernel/numa_balancing 2>/dev/null)"
if [[ "$nb" == "0" ]]; then
  pass "kernel.numa_balancing=0"
else
  skipw "kernel.numa_balancing=0" "currently '$nb'. FIX: sudo sysctl -w kernel.numa_balancing=0 (vLLM cross-NUMA KV faults otherwise)"
fi

# --- Verdict ---------------------------------------------------------------
n_fail="$(count_fails)"
hdr "preflight result: $([[ $n_fail -eq 0 ]] && echo "${C_GRN}GO${C_RST}" || echo "${C_RED}NO-GO ($n_fail failed)${C_RST}")"
exit $(( n_fail > 0 ? 1 : 0 ))
