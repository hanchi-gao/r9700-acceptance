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

    def __init__(self, components="all", duration=1800, mode="full", parent=None):
        super().__init__(parent)
        self.components = components
        self.duration = duration
        self.mode = mode
        self._proc = None
        self._start_time = None

    @property
    def elapsed(self):
        if self._start_time:
            return time.time() - self._start_time
        return 0

    def run(self):
        results_dir = os.path.join(REPO_ROOT, "results", "dashboard_live")
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

        self._start_time = time.time()
        self.log_line.emit(f"[START] mode={self.mode} components={self.components} duration={self.duration}s")
        self.started.emit()

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
            rc = self._proc.returncode
        except Exception as e:
            self.log_line.emit(f"[ERROR] {e}")
            rc = -1

        self._proc = None
        self._start_time = None
        self.log_line.emit(f"[DONE] exit code {rc}")
        self.finished_burnin.emit(rc)
        self.stopped.emit()

    def stop(self):
        if self._proc and self._proc.poll() is None:
            try:
                os.killpg(os.getpgid(self._proc.pid), signal.SIGTERM)
                self.log_line.emit("[STOP] sent SIGTERM to process group")
            except ProcessLookupError:
                pass
