#!/usr/bin/env bash
# stress/ssd.sh — fio random+sequential R/W with a MANDATORY write guard.
# This is the one mistake that destroys a customer machine (plan §8), so the
# guard refuses to write to any device that hosts a mounted filesystem.
#
# Usage:
#   ./stress/ssd.sh [--duration SECONDS] [--target PATH]
#     --target is EITHER a writable file path on a mounted data FS (default,
#     file-based, cleaned up afterwards) OR an explicitly named UNMOUNTED raw
#     device. We NEVER default to a raw device.
#
# Default target: $RESULTS_DIR/fio_test.tmp (a file on whatever FS holds the
# repo). That is safe (file-based) even on the OS disk.

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

TARGET="$RESULTS_DIR/fio_test.tmp"
DEADLINE="$(resolve_deadline "$@")"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   TARGET="$2";   shift 2;;
    *) shift;;
  esac
done
DURATION=$(( DEADLINE - $(date +%s) )); (( DURATION < 1 )) && DURATION=1

# --- Resolve the OS root's parent disk, e.g. /dev/nvme0n1p2 -> /dev/nvme0n1 ---
root_src="$(findmnt -no SOURCE / 2>/dev/null)"
root_disk=""
if [[ -n "$root_src" ]]; then
  root_disk="/dev/$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)"
  [[ "$root_disk" == "/dev/" ]] && root_disk="$root_src"
fi
info "ssd: root filesystem source=$root_src  parent disk=$root_disk"
info "ssd: requested target=$TARGET"

# --- WRITE GUARD -----------------------------------------------------------
guard_ok=0
if [[ -b "$TARGET" ]]; then
  # Target is a block device — only allowed if it is NOT the root disk AND not mounted.
  tgt_canon="$(readlink -f "$TARGET")"
  if [[ "$tgt_canon" == "$root_disk"* || "$tgt_canon" == "$root_src" ]]; then
    die "REFUSING: $TARGET is (part of) the OS root disk $root_disk. Aborting before any write."
  fi
  if findmnt -S "$tgt_canon" >/dev/null 2>&1 || lsblk -no MOUNTPOINT "$tgt_canon" 2>/dev/null | grep -q .; then
    die "REFUSING: $TARGET has a mounted filesystem. Aborting before any write."
  fi
  warn "ssd: target is a RAW block device $tgt_canon — fio WILL overwrite it. (verified: not root, not mounted)"
  FIO_TARGET=( --filename="$tgt_canon" )
  guard_ok=1
else
  # File-based: ensure the directory exists and is writable. Safe on any FS.
  mkdir -p "$(dirname "$TARGET")"
  : > "$TARGET" 2>/dev/null || die "cannot create test file $TARGET"
  FIO_TARGET=( --filename="$TARGET" --size=8G )
  guard_ok=1
fi
(( guard_ok == 1 )) || die "write guard did not pass — refusing to run fio"
info "ssd: write guard PASSED. Proceeding with fio."

trap 'rm -f "$TARGET" 2>/dev/null; cleanup_tracked' EXIT INT TERM

run_fio() {  # run_fio name rw bs
  local name="$1" rw="$2" bs="$3"
  fio --name="$name" --rw="$rw" --bs="$bs" --ioengine=libaio --direct=1 \
      --iodepth=32 --numjobs=4 --runtime="$PER_JOB" --time_based --group_reporting \
      --output-format=json "${FIO_TARGET[@]}" 2>/dev/null
}

# 3 fio jobs run sequentially — split the total duration across them so the SSD
# stage stays within the shared burn-in deadline.
PER_JOB=$(( DURATION / 3 )); (( PER_JOB < 5 )) && PER_JOB=5

# Sequential read/write throughput; random for IOPS sanity.
for spec in "seqread:read:1M" "seqwrite:write:1M" "randrw:randrw:4k"; do
  name="${spec%%:*}"; rest="${spec#*:}"; rw="${rest%%:*}"; bs="${rest##*:}"
  out="$(run_fio "$name" "$rw" "$bs")"
  echo "$out" > "$RESULTS_DIR/fio_${name}.json"
  rmbps="$(python3 -c "import json,sys; d=json.load(open('$RESULTS_DIR/fio_${name}.json')); j=d['jobs'][0]; print(round(j['read']['bw']/1024,1), round(j['write']['bw']/1024,1))" 2>/dev/null)"
  read -r r w <<<"$rmbps"
  info "ssd: $name read=${r}MB/s write=${w}MB/s"
  case "$name" in
    seqread)  assert_ge "fio seq read MB/s"  "$SSD_SEQ_READ_FLOOR_MBPS"  "${r:-0}";;
    seqwrite) assert_ge "fio seq write MB/s" "$SSD_SEQ_WRITE_FLOOR_MBPS" "${w:-0}";;
  esac
done

info "ssd: done"
