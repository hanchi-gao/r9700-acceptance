#!/usr/bin/env bash
# run_with_nvme.sh — wrapper: auto-detect NVMe, mount, run acceptance, umount.
# Usage:  sudo ./run_with_nvme.sh --serial SN123 --duration 30m
#
# Auto-detects the first NVMe that is not the OS disk and not already mounted.
# Override with:  NVME_DEV=/dev/nvme1n1 sudo ./run_with_nvme.sh ...

set -uo pipefail

NVME_MNT="${NVME_MNT:-/mnt/nvme-test}"
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Auto-detect NVMe: find all nvme block devices, exclude the one backing /
_detect_nvme() {
  local os_disk
  os_disk="$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1)"
  os_disk="${os_disk:-$(lsblk -dn -o NAME,TYPE | awk '$2=="disk" && $1!~/nvme/{print $1}' | head -1)}"

  local dev
  while IFS= read -r dev; do
    [[ "$dev" == "$os_disk" ]] && continue
    # skip if already mounted
    mountpoint -q "/dev/$dev" 2>/dev/null && continue
    lsblk -n -o MOUNTPOINT "/dev/$dev" 2>/dev/null | grep -q '.' && continue
    echo "/dev/$dev"
    return 0
  done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk" && $1~/nvme/{print $1}')

  return 1
}

if [[ -z "${NVME_DEV:-}" ]]; then
  NVME_DEV="$(_detect_nvme)" || { echo "ERROR: no unmounted NVMe found. Set NVME_DEV= manually." >&2; exit 1; }
  echo "auto-detected NVMe: $NVME_DEV"
fi

mounted=0
cleanup() {
  if (( mounted )); then
    rm -f "$NVME_MNT/fio_test.tmp"
    if [[ $EUID -eq 0 ]]; then
      umount "$NVME_MNT" 2>/dev/null || true
    else
      udisksctl unmount -b "$NVME_DEV" 2>/dev/null || true
    fi
  fi
}
trap cleanup EXIT INT TERM

# Check if already mounted
existing_mnt="$(lsblk -n -o MOUNTPOINT "$NVME_DEV" 2>/dev/null | grep -m1 '.')"
if [[ -n "$existing_mnt" ]]; then
  NVME_MNT="$existing_mnt"
  echo "$NVME_DEV already mounted at $NVME_MNT"
elif [[ $EUID -eq 0 ]]; then
  mkdir -p "$NVME_MNT"
  mount "$NVME_DEV" "$NVME_MNT" || { echo "ERROR: cannot mount $NVME_DEV" >&2; exit 1; }
  echo "mounted $NVME_DEV -> $NVME_MNT"
  mounted=1
else
  mnt_out="$(udisksctl mount -b "$NVME_DEV" 2>&1)" \
    || { echo "ERROR: cannot mount $NVME_DEV: $mnt_out" >&2; exit 1; }
  NVME_MNT="${mnt_out##* at }"; NVME_MNT="${NVME_MNT%.}"
  echo "mounted $NVME_DEV -> $NVME_MNT"
  mounted=1
fi

"$REPO_ROOT/run_acceptance.sh" "$@" --fio-target "$NVME_MNT/fio_test.tmp"
