#!/usr/bin/env bash
# run_with_nvme.sh — wrapper: auto-mount NVMe, run acceptance, auto-umount.
# Usage:  sudo ./run_with_nvme.sh --serial SN123 --duration 30m
#
# Mounts /dev/nvme0n1p2 -> /mnt/nvme-test, points fio there, cleans up on exit.

set -uo pipefail

NVME_DEV="${NVME_DEV:-/dev/nvme0n1p2}"
NVME_MNT="${NVME_MNT:-/mnt/nvme-test}"
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

mounted=0
cleanup() {
  if (( mounted )); then
    rm -f "$NVME_MNT/fio_test.tmp"
    umount "$NVME_MNT" 2>/dev/null && echo "unmounted $NVME_MNT"
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$NVME_MNT"
if mountpoint -q "$NVME_MNT" 2>/dev/null; then
  echo "$NVME_MNT already mounted"
else
  mount "$NVME_DEV" "$NVME_MNT" || { echo "ERROR: cannot mount $NVME_DEV" >&2; exit 1; }
  echo "mounted $NVME_DEV -> $NVME_MNT"
fi
mounted=1

"$REPO_ROOT/run_acceptance.sh" "$@" --fio-target "$NVME_MNT/fio_test.tmp"
