"""Burn-in process manager as QThread."""
import os
import pwd
import re
import signal
import subprocess
import time

from PyQt6.QtCore import QThread, pyqtSignal

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NVME_MNT = "/mnt/nvme-test"


def _real_home():
    """Return the original (non-root) user's home directory."""
    user = os.environ.get("SUDO_USER") or os.environ.get("USER", "")
    try:
        return pwd.getpwnam(user).pw_dir
    except Exception:
        return os.path.expanduser("~")


def _chown_to_user(path):
    """Recursively chown path to the original (non-root) user."""
    user = os.environ.get("SUDO_USER") or os.environ.get("USER", "")
    if not user or os.geteuid() != 0:
        return
    try:
        entry = pwd.getpwnam(user)
        uid, gid = entry.pw_uid, entry.pw_gid
        for dirpath, dirnames, filenames in os.walk(path, topdown=False):
            for name in filenames + dirnames:
                try:
                    os.chown(os.path.join(dirpath, name), uid, gid)
                except OSError:
                    pass
        os.chown(path, uid, gid)
    except Exception:
        pass


def _os_disk_name():
    try:
        src = subprocess.check_output(["findmnt", "-n", "-o", "SOURCE", "/"], text=True).strip()
        return re.sub(r'p?\d+$', '', os.path.basename(src))
    except Exception:
        return ""


def _nvme_mountpoint(dev):
    """Return first active mountpoint for dev (or its partitions), or None."""
    try:
        out = subprocess.check_output(["lsblk", "-n", "-o", "MOUNTPOINT", dev], text=True)
        for mnt in out.splitlines():
            mnt = mnt.strip()
            if mnt and os.path.isdir(mnt):
                return mnt
    except Exception:
        pass
    return None


def _mountable_device(disk_dev):
    """Return the actual device to mount for a given disk:
    - the disk itself if it has a whole-disk filesystem
    - otherwise the largest ext4/xfs/btrfs partition on it"""
    try:
        fstype = subprocess.check_output(
            ["lsblk", "-dn", "-o", "FSTYPE", disk_dev], text=True
        ).strip()
        if fstype:
            return disk_dev
    except Exception:
        pass

    try:
        out = subprocess.check_output(
            ["lsblk", "-n", "-o", "NAME,FSTYPE,SIZE", disk_dev], text=True
        )
        best = None
        best_bytes = 0
        for line in out.splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            name, fstype = parts[0].lstrip("├─└─"), parts[1]
            if fstype not in ("ext4", "xfs", "btrfs"):
                continue
            sz = parts[2]
            try:
                mult = {"G": 1 << 30, "T": 1 << 40, "M": 1 << 20}.get(sz[-1], 1)
                b = float(sz[:-1]) * mult
            except Exception:
                b = 0
            if b > best_bytes:
                best_bytes = b
                best = f"/dev/{name}"
        if best:
            return best
    except Exception:
        pass

    return disk_dev


def list_nvme_drives():
    """Return list of (dev, mnt_or_None, size, model) for all non-OS NVMe disks."""
    os_disk = _os_disk_name()
    try:
        out = subprocess.check_output(
            ["lsblk", "-dn", "-o", "NAME,TYPE,SIZE,MODEL"], text=True
        )
    except Exception:
        return []
    results = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 2:
            continue
        name, typ = parts[0], parts[1]
        if "nvme" not in name or typ != "disk":
            continue
        if name == os_disk:
            continue
        dev = f"/dev/{name}"
        size = parts[2] if len(parts) > 2 else ""
        model = parts[3].strip() if len(parts) > 3 else ""
        results.append((dev, _nvme_mountpoint(dev), size, model))
    return results


class BurninThread(QThread):
    started = pyqtSignal()
    stopped = pyqtSignal()
    log_line = pyqtSignal(str)
    finished_burnin = pyqtSignal(int)  # exit code

    def __init__(self, components="all", duration=1800, mode="full",
                 gpu_ids="", full_acceptance=False, serial="",
                 nvme_dev="", parent=None):
        super().__init__(parent)
        self.components = components
        self.duration = duration
        self.mode = mode
        self.gpu_ids = gpu_ids
        self.full_acceptance = full_acceptance
        self.serial = serial
        self.nvme_dev = nvme_dev        # "" = auto-detect
        self._proc = None
        self._start_time = None
        self._nvme_we_mounted = False
        ts = time.strftime("%Y%m%d_%H%M%S")
        results_base = os.path.join(_real_home(), "r9700-results")
        if full_acceptance and serial:
            self.results_dir = os.path.join(results_base, f"{serial}_{ts}")
        else:
            self.results_dir = os.path.join(results_base, f"dashboard_{ts}")

    @property
    def elapsed(self):
        if self._start_time:
            return time.time() - self._start_time
        return 0

    def _mount_nvme(self):
        """Mount selected (or auto-detected) NVMe. Returns fio target path or None."""
        disk = self.nvme_dev or None

        if not disk:
            drives = list_nvme_drives()
            for dev, mnt, size, model in drives:
                if mnt:
                    self.log_line.emit(f"[NVMe] {dev} already mounted at {mnt}")
                    return os.path.join(mnt, "fio_test.tmp")
                disk = dev
                break
            if not disk:
                self.log_line.emit("[NVMe] no non-OS NVMe found — fio will use default path")
                return None

        mnt = _nvme_mountpoint(disk)
        if mnt:
            self.log_line.emit(f"[NVMe] {disk} already mounted at {mnt}")
            return os.path.join(mnt, "fio_test.tmp")

        mount_dev = _mountable_device(disk)

        try:
            if os.geteuid() == 0:
                os.makedirs(NVME_MNT, exist_ok=True)
                subprocess.run(["mount", mount_dev, NVME_MNT], check=True, capture_output=True)
                mnt = NVME_MNT
            else:
                result = subprocess.run(
                    ["udisksctl", "mount", "-b", mount_dev],
                    check=True, capture_output=True, text=True,
                )
                mnt = result.stdout.strip().split(" at ")[-1].rstrip(".")
            self._nvme_mnt_dev = mount_dev
            self._nvme_we_mounted = True
            self.log_line.emit(f"[NVMe] mounted {mount_dev} -> {mnt}")
            return os.path.join(mnt, "fio_test.tmp")
        except Exception as e:
            self.log_line.emit(f"[NVMe] mount failed ({e}) — fio will use default path")
            return None

    def _umount_nvme(self):
        """Unmount NVMe only if we mounted it."""
        if not self._nvme_we_mounted:
            return
        dev = getattr(self, "_nvme_mnt_dev", None)
        if dev:
            try:
                if os.geteuid() == 0:
                    subprocess.run(["umount", NVME_MNT], check=True, capture_output=True)
                else:
                    subprocess.run(["udisksctl", "unmount", "-b", dev],
                                   check=True, capture_output=True)
                self.log_line.emit(f"[NVMe] unmounted {dev}")
            except Exception as e:
                self.log_line.emit(f"[NVMe] umount failed: {e}")
        self._nvme_we_mounted = False

    def run(self):
        self._start_time = time.time()

        if self.full_acceptance:
            self._run_acceptance()
        else:
            self._run_burnin()

        self._umount_nvme()
        _chown_to_user(self.results_dir)
        self._proc = None
        self._start_time = None
        self.stopped.emit()

    def _run_burnin(self):
        """Quick burn-in via combined.sh — no baseline/monitor/postcheck."""
        results_dir = self.results_dir
        os.makedirs(results_dir, exist_ok=True)
        # Give ownership to the original user so they can read without sudo
        _chown_to_user(results_dir)

        env = os.environ.copy()
        env["RESULTS_DIR"] = results_dir
        env["CONFIG_FILE"] = os.path.join(REPO_ROOT, "expected_config.yaml")
        if self.mode == "light":
            env["BURNIN_MODE"] = "light"

        fio_target = self._mount_nvme()

        cmd = [
            os.path.join(REPO_ROOT, "stress", "combined.sh"),
            "--duration", str(self.duration),
            "--components", self.components,
        ]
        if self.gpu_ids:
            cmd += ["--gpu-ids", self.gpu_ids]
        if fio_target:
            cmd += ["--fio-target", fio_target]

        self.log_line.emit(f"[START] mode={self.mode} components={self.components} duration={self.duration}s")
        self.started.emit()
        rc = self._exec(cmd, env)
        self.log_line.emit(f"[DONE] exit code {rc}")
        self.finished_burnin.emit(rc)

    def _run_acceptance(self):
        """Full acceptance via run_with_nvme.sh — handles its own mount/umount."""
        env = os.environ.copy()
        if self.mode == "light":
            env["BURNIN_MODE"] = "light"
        if self.nvme_dev:
            env["NVME_DEV"] = _mountable_device(self.nvme_dev)

        dur_m = max(1, self.duration // 60)
        cmd = [
            os.path.join(REPO_ROOT, "run_with_nvme.sh"),
            "--serial", self.serial,
            "--duration", f"{dur_m}m",
            "--burnin", self.components,
        ]

        self.log_line.emit(f"[ACCEPTANCE] serial={self.serial} duration={dur_m}m components={self.components}")
        self.started.emit()
        rc = self._exec(cmd, env)
        self.log_line.emit(f"[DONE] exit code {rc}")
        self.finished_burnin.emit(rc)

    def _exec(self, cmd, env):
        try:
            self._proc = subprocess.Popen(
                cmd, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True,
                text=True,
            )
            for line in self._proc.stdout:
                self.log_line.emit(line.rstrip())
            self._proc.wait()
            return self._proc.returncode
        except Exception as e:
            self.log_line.emit(f"[ERROR] {e}")
            return -1

    def stop(self):
        if self._proc and self._proc.poll() is None:
            try:
                os.killpg(os.getpgid(self._proc.pid), signal.SIGTERM)
                self.log_line.emit("[STOP] sent SIGTERM to process group")
            except (ProcessLookupError, OSError):
                pass

    def _kill_proc_group(self):
        """Escalate to SIGKILL — use after SIGTERM timeout."""
        if self._proc:
            try:
                os.killpg(os.getpgid(self._proc.pid), signal.SIGKILL)
            except (ProcessLookupError, OSError):
                pass
