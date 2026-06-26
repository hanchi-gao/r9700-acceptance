"""Burn-in process manager as QThread."""
import os
import signal
import subprocess
import time

from PyQt6.QtCore import QThread, pyqtSignal

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class BurninThread(QThread):
    started = pyqtSignal()
    stopped = pyqtSignal()
    log_line = pyqtSignal(str)
    finished_burnin = pyqtSignal(int)  # exit code

    def __init__(self, components="all", duration=1800, mode="full",
                 gpu_ids="", full_acceptance=False, serial="", parent=None):
        super().__init__(parent)
        self.components = components
        self.duration = duration
        self.mode = mode
        self.gpu_ids = gpu_ids
        self.full_acceptance = full_acceptance
        self.serial = serial
        self._proc = None
        self._start_time = None
        ts = time.strftime("%Y%m%d_%H%M%S")
        if full_acceptance and serial:
            self.results_dir = os.path.join(REPO_ROOT, "results", f"{serial}_{ts}")
        else:
            self.results_dir = os.path.join(REPO_ROOT, "results", f"dashboard_{ts}")

    @property
    def elapsed(self):
        if self._start_time:
            return time.time() - self._start_time
        return 0

    def run(self):
        self._start_time = time.time()

        if self.full_acceptance:
            self._run_acceptance()
        else:
            self._run_burnin()

        self._proc = None
        self._start_time = None
        self.stopped.emit()

    def _run_burnin(self):
        """Quick burn-in via combined.sh — no baseline/monitor/postcheck."""
        results_dir = self.results_dir
        os.makedirs(results_dir, exist_ok=True)

        env = os.environ.copy()
        env["RESULTS_DIR"] = results_dir
        env["CONFIG_FILE"] = os.path.join(REPO_ROOT, "expected_config.yaml")
        if self.mode == "light":
            env["BURNIN_MODE"] = "light"

        cmd = [
            os.path.join(REPO_ROOT, "stress", "combined.sh"),
            "--duration", str(self.duration),
            "--components", self.components,
        ]
        if self.gpu_ids:
            cmd += ["--gpu-ids", self.gpu_ids]

        self.log_line.emit(f"[START] mode={self.mode} components={self.components} duration={self.duration}s")
        self.started.emit()
        rc = self._exec(cmd, env)
        self.log_line.emit(f"[DONE] exit code {rc}")
        self.finished_burnin.emit(rc)

    def _run_acceptance(self):
        """Full acceptance via run_acceptance.sh — preflight+inventory+burn-in+postcheck+report."""
        env = os.environ.copy()
        if self.mode == "light":
            env["BURNIN_MODE"] = "light"

        dur_m = max(1, self.duration // 60)
        cmd = [
            os.path.join(REPO_ROOT, "run_acceptance.sh"),
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
            except ProcessLookupError:
                pass
