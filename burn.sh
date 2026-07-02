#!/usr/bin/env bash
# burn.sh — headless server burn-in for R9700 machines. No GUI required.
#
# Usage:
#   sudo ./burn.sh [--duration 30m] [--disk /dev/sdb] [--components gpu,cpu,ssd] [--serial SN]
#
#   --duration   30m / 1h / 3600 (default: 30m)
#   --disk       block device to fio-test; omit = auto-detect non-OS / non-self disk
#   --components gpu,cpu,ssd or any subset; default: all
#   --serial     label for results folder; default: hostname_timestamp

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "$REPO_ROOT/lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
hdr()  { echo -e "\n${YELLOW}==>${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── args ─────────────────────────────────────────────────────────────────────
DURATION="30m"
DISK=""
COMPONENTS="all"
SERIAL="${HOSTNAME}_$(date +%Y%m%d_%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --duration)   DURATION="$2";    shift 2;;
    --disk)       DISK="$2";        shift 2;;
    --components) COMPONENTS="$2";  shift 2;;
    --serial)     SERIAL="$2";      shift 2;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \?//'
      exit 0;;
    *) shift;;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root: sudo ./burn.sh"

# ── duration ─────────────────────────────────────────────────────────────────
dur_to_secs() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 ));;
    *m) echo $(( ${1%m} * 60 ));;
    *s) echo "${1%s}";;
    *)  echo "$1";;
  esac
}
DUR_S="$(dur_to_secs "$DURATION")"

# ── results dir ───────────────────────────────────────────────────────────────
REAL_USER="${SUDO_USER:-${USER}}"
CONF_PATH="$REPO_ROOT/results_path.conf"
if [[ -f "$CONF_PATH" ]]; then
  RESULTS_BASE="$(cat "$CONF_PATH")"
else
  REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
  RESULTS_BASE="$REAL_HOME/r9700-results"
fi
export RESULTS_DIR="$RESULTS_BASE/$SERIAL"
mkdir -p "$RESULTS_DIR"
chown "$REAL_USER:" "$RESULTS_BASE" "$RESULTS_DIR" 2>/dev/null || true
export CONFIG_FILE="$REPO_ROOT/expected_config.yaml"

# ── disk auto-detect ──────────────────────────────────────────────────────────
want_ssd() { [[ "$COMPONENTS" == "all" ]] || [[ ",$COMPONENTS," == *",ssd,"* ]]; }

_self_disk() {
  lsblk -no PKNAME "$(df "$REPO_ROOT" | awk 'NR==2{print $1}')" 2>/dev/null | head -1
}
_os_disk() {
  lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1
}

NVME_MNT_USED=""
FIO_TARGET=""

if want_ssd; then
  if [[ -n "$DISK" ]]; then
    # explicit disk given
    [[ -b "$DISK" ]] || die "--disk $DISK is not a block device"
  else
    # auto-detect: skip OS disk and the disk this project is on
    OS_DISK="$(_os_disk)"
    SELF_DISK="$(_self_disk)"
    for dev in $(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}'); do
      [[ "$dev" == "$OS_DISK"   ]] && continue
      [[ "$dev" == "$SELF_DISK" ]] && continue
      DISK="/dev/$dev"
      info "auto-detected test disk: $DISK"
      break
    done
  fi

  if [[ -n "$DISK" ]]; then
    # Try to find a mountable partition with a filesystem
    MNT_DEV="$DISK"
    FSTYPE="$(lsblk -dn -o FSTYPE "$DISK" 2>/dev/null)"
    if [[ -z "$FSTYPE" ]]; then
      # Look for largest partition with a known fs
      while IFS= read -r line; do
        name="${line%% *}"; fs="${line##* }"
        [[ "$fs" =~ ^(ext4|xfs|btrfs|vfat)$ ]] || continue
        MNT_DEV="/dev/${name//[├─└─]/}"
        FSTYPE="$fs"
      done < <(lsblk -n -o NAME,FSTYPE "$DISK" | grep -v "^$DISK\b")
    fi

    # Mount if not already mounted
    EXISTING_MNT="$(lsblk -n -o MOUNTPOINT "$MNT_DEV" 2>/dev/null | grep -v '^$' | head -1)"
    if [[ -n "$EXISTING_MNT" ]]; then
      FIO_TARGET="$EXISTING_MNT/fio_test.tmp"
      info "disk already mounted at $EXISTING_MNT"
    elif [[ -n "$FSTYPE" ]]; then
      NVME_MNT="/mnt/r9700-burn-ssd"
      mkdir -p "$NVME_MNT"
      mount "$MNT_DEV" "$NVME_MNT" && {
        NVME_MNT_USED="$NVME_MNT"
        FIO_TARGET="$NVME_MNT/fio_test.tmp"
        info "mounted $MNT_DEV -> $NVME_MNT"
      } || {
        warn "mount failed — will fio raw device (data will be overwritten!)"
        FIO_TARGET="$DISK"
      }
    else
      warn "no filesystem on $DISK — fio will write raw (data will be overwritten!)"
      FIO_TARGET="$DISK"
    fi
  else
    warn "no test disk found — skipping SSD burn-in"
    COMPONENTS="$(echo "$COMPONENTS" | sed 's/,\?ssd,\?/,/;s/^,\|,$//;s/all/gpu,cpu/')"
  fi
fi

cleanup_burn() {
  [[ -n "$NVME_MNT_USED" ]] && umount "$NVME_MNT_USED" 2>/dev/null || true
  [[ -n "$FIO_TARGET" && "$FIO_TARGET" == */fio_test.tmp ]] && rm -f "$FIO_TARGET" 2>/dev/null || true
  chown -R "$REAL_USER:" "$RESULTS_DIR" 2>/dev/null || true
}
trap cleanup_burn EXIT

# ── header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  R9700 Burn-in${NC}"
echo -e "  serial:     $SERIAL"
echo -e "  duration:   $DURATION  (${DUR_S}s)"
echo -e "  components: $COMPONENTS"
[[ -n "$DISK" ]] && echo -e "  test disk:  $DISK -> ${FIO_TARGET:-raw}"
echo -e "  results:    $RESULTS_DIR"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""

# ── run burn-in ───────────────────────────────────────────────────────────────
CMD=("$REPO_ROOT/stress/combined.sh"
     "--duration" "$DUR_S"
     "--components" "$COMPONENTS")
[[ -n "$FIO_TARGET" ]] && CMD+=("--fio-target" "$FIO_TARGET")

"${CMD[@]}" 2>&1 | tee "$RESULTS_DIR/burnin.log"
RC="${PIPESTATUS[0]}"

# ── result ────────────────────────────────────────────────────────────────────
echo ""
if [[ "$RC" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}"
  echo "  ██████╗  █████╗ ███████╗███████╗"
  echo "  ██╔══██╗██╔══██╗██╔════╝██╔════╝"
  echo "  ██████╔╝███████║███████╗███████╗ "
  echo "  ██╔═══╝ ██╔══██║╚════██║╚════██║"
  echo "  ██║     ██║  ██║███████║███████║"
  echo "  ╚═╝     ╚═╝  ╚═╝╚══════╝╚══════╝"
  echo -e "${NC}"
  echo -e "  Results: $RESULTS_DIR"
else
  echo -e "${RED}${BOLD}"
  echo "  ███████╗ █████╗ ██╗██╗      "
  echo "  ██╔════╝██╔══██╗██║██║      "
  echo "  █████╗  ███████║██║██║      "
  echo "  ██╔══╝  ██╔══██║██║██║      "
  echo "  ██║     ██║  ██║██║███████╗ "
  echo "  ╚═╝     ╚═╝  ╚═╝╚═╝╚══════╝"
  echo -e "${NC}"
  echo -e "  Results: $RESULTS_DIR"
  echo -e "  Log:     $RESULTS_DIR/burnin.log"
fi

exit "$RC"
