#!/usr/bin/env bash
# lib/common.sh
# Shared helpers for the acceptance suite: logging, colour, PASS/FAIL
# accumulator, expected_config.yaml reader, GPU enumeration helpers.
#
# Source this from every stage script:  source "$(dirname "$0")/lib/common.sh"
# It is safe to source more than once.

[[ -n "${_ACCEPTANCE_COMMON_LOADED:-}" ]] && return 0
_ACCEPTANCE_COMMON_LOADED=1

set -o pipefail

# ----------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------
# REPO_ROOT = directory that contains this lib/ folder.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/expected_config.yaml}"
export CONFIG_FILE

# RESULTS_DIR is set by run_acceptance.sh and exported to children. When a
# stage script is run standalone, fall back to a scratch dir so logging works.
if [[ -z "${RESULTS_DIR:-}" ]]; then
  RESULTS_DIR="$REPO_ROOT/results/standalone_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$RESULTS_DIR"
export RESULTS_DIR

# ----------------------------------------------------------------------------
# Colour / logging
# ----------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'
  C_BOLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""; C_RST=""
fi

_ts() { date '+%H:%M:%S'; }
log()  { printf '%s %s\n'        "$(_ts)" "$*"; }
info() { printf '%s %s%s%s\n'    "$(_ts)" "$C_BLU" "$*" "$C_RST"; }
warn() { printf '%s %s[WARN]%s %s\n' "$(_ts)" "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s %s[FATAL]%s %s\n' "$(_ts)" "$C_RED" "$C_RST" "$*" >&2; exit 1; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RST"; }

# ----------------------------------------------------------------------------
# PASS/FAIL accumulator
# ----------------------------------------------------------------------------
# Each check appends one line "STATUS<TAB>check name<TAB>detail" to
# $RESULTS_DIR/checks.tsv. Stage exit code derives from whether any FAIL exists.
CHECKS_TSV="$RESULTS_DIR/checks.tsv"
: > "$CHECKS_TSV.$$" 2>/dev/null || true   # per-process scratch not used; kept simple
touch "$CHECKS_TSV"

_record() {  # _record STATUS "name" "detail"
  local status="$1" name="$2" detail="${3:-}"
  printf '%s\t%s\t%s\n' "$status" "$name" "$detail" >> "$CHECKS_TSV"
}

pass() { _record PASS "$1" "${2:-}"; printf '%s  %s[PASS]%s %s%s\n' "$(_ts)" "$C_GRN" "$C_RST" "$1" "${2:+  ($2)}"; }
fail() { _record FAIL "$1" "${2:-}"; printf '%s  %s[FAIL]%s %s%s\n' "$(_ts)" "$C_RED" "$C_RST" "$1" "${2:+  ($2)}" >&2; }
skipw(){ _record WARN "$1" "${2:-}"; printf '%s  %s[WARN]%s %s%s\n' "$(_ts)" "$C_YEL" "$C_RST" "$1" "${2:+  ($2)}" >&2; }

# assert NAME EXPECTED ACTUAL [detail-extra]   -> pass if equal else fail
assert_eq() {
  local name="$1" exp="$2" act="$3" extra="${4:-}"
  if [[ "$exp" == "$act" ]]; then
    pass "$name" "expected=$exp actual=$act${extra:+ $extra}"
  else
    fail "$name" "expected=$exp actual=$act${extra:+ $extra}"
  fi
}

# assert_ge NAME MIN ACTUAL  (integer or float) -> pass if actual >= min
assert_ge() {
  local name="$1" min="$2" act="$3" extra="${4:-}"
  if awk -v a="$act" -v m="$min" 'BEGIN{exit !(a+0 >= m+0)}'; then
    pass "$name" "min=$min actual=$act${extra:+ $extra}"
  else
    fail "$name" "min=$min actual=$act${extra:+ $extra}"
  fi
}

# Count fails recorded so far (whole run).
count_fails() { grep -c $'^FAIL\t' "$CHECKS_TSV" 2>/dev/null || echo 0; }

# ----------------------------------------------------------------------------
# expected_config.yaml reader (python3 + PyYAML)
# cfg KEYPATH                e.g.  cfg gpu.count          -> 4
# cfg_list KEYPATH FIELD     e.g.  cfg_list gpu.topology bdf  -> one bdf per line
# ----------------------------------------------------------------------------
cfg() {
  python3 - "$CONFIG_FILE" "$1" <<'PY'
import sys, yaml
f, path = sys.argv[1], sys.argv[2]
with open(f) as fh:
    d = yaml.safe_load(fh)
for k in path.split('.'):
    if d is None: break
    d = d.get(k) if isinstance(d, dict) else None
print('' if d is None else d)
PY
}

cfg_list() {  # cfg_list gpu.topology bdf
  python3 - "$CONFIG_FILE" "$1" "$2" <<'PY'
import sys, yaml
f, path, field = sys.argv[1], sys.argv[2], sys.argv[3]
with open(f) as fh:
    d = yaml.safe_load(fh)
for k in path.split('.'):
    d = d.get(k) if isinstance(d, dict) else None
if isinstance(d, list):
    for item in d:
        if isinstance(item, dict):
            print(item.get(field, ''))
        else:
            print(item)
PY
}

# ----------------------------------------------------------------------------
# GPU helpers
# ----------------------------------------------------------------------------
GPU_PCI_ID="${GPU_PCI_ID:-$(cfg gpu.pci_id 2>/dev/null)}"
GPU_PCI_ID="${GPU_PCI_ID:-1002:7551}"

# List GPU BDFs in lspci order, normalised to lowercase 0000:xx:xx.x form.
gpu_bdfs() {
  lspci -D -d "$GPU_PCI_ID" 2>/dev/null | awk '{print tolower($1)}'
}

# rocm-smi index -> BDF, lowercase, e.g. "0 0000:03:00.0"
gpu_index_bdf() {
  rocm-smi --showbus 2>/dev/null \
    | awk -F'PCI Bus:' '/PCI Bus:/{gsub(/[ \t]/,"",$2); idx=$0; sub(/.*GPU\[/,"",idx); sub(/\].*/,"",idx); print idx"\t"tolower($2)}'
}

# Number of GPUs visible to rocm-smi.
gpu_count() { gpu_bdfs | grep -c . ; }

# Resolve render/video numeric GIDs for docker --group-add (critical, see plan §12).
render_gid() { getent group render | cut -d: -f3; }
video_gid()  { getent group video  | cut -d: -f3; }

# Standard docker GPU args (devices + resolved GIDs + seccomp).
docker_gpu_args() {
  local rgid vgid
  rgid="$(render_gid)"; vgid="$(video_gid)"
  printf '%s' "--device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined"
  [[ -n "$rgid" ]] && printf ' --group-add %s' "$rgid"
  [[ -n "$vgid" ]] && printf ' --group-add %s' "$vgid"
}

# VRAM container image (overridable via env).
VRAM_IMAGE="${VRAM_IMAGE:-asrock_henrygao/rocm-vllm:rocm7.1_ubuntu22.04_py3.12_pytorch_release_2.9.0_vllm0.13.0}"
export VRAM_IMAGE

# ----------------------------------------------------------------------------
# Process / container cleanup tracking (plan §8)
# ----------------------------------------------------------------------------
TRACKED_PIDS=()
TRACKED_CONTAINERS=()
track_pid()       { TRACKED_PIDS+=("$1"); }
track_container() { TRACKED_CONTAINERS+=("$1"); }

cleanup_tracked() {
  local p c
  for p in "${TRACKED_PIDS[@]:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null || true
  done
  for c in "${TRACKED_CONTAINERS[@]:-}"; do
    [[ -n "$c" ]] && docker stop -t 5 "$c" >/dev/null 2>&1 || true
  done
}
# Stage scripts should:  trap cleanup_tracked EXIT INT TERM
