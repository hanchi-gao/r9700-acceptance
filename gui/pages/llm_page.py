"""LLM inference test page — environment detection, model download, per-card benchmark."""
import os
import glob
import subprocess
import threading

from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QComboBox, QTextEdit, QFrame, QProgressBar, QGridLayout,
    QTableWidget, QTableWidgetItem, QHeaderView,
)
from PyQt6.QtCore import Qt, QThread, pyqtSignal

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODELS_DIR = os.path.join(REPO_ROOT, "models")
LLAMA_BIN = os.path.join(REPO_ROOT, "build", "llama-cli")

DEFAULT_MODEL_URL = "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
DEFAULT_MODEL_NAME = "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"


MIN_VRAM_MB = 8192  # need at least 8GB for 8B Q4 model

def _check_env():
    """Return dict of environment status."""
    checks = {}
    checks["llama_cli"] = os.path.isfile(LLAMA_BIN) and os.access(LLAMA_BIN, os.X_OK)
    checks["models"] = sorted(glob.glob(os.path.join(MODELS_DIR, "*.gguf")))
    # Only count GPUs with enough VRAM for LLM inference
    gpus = []
    for card_dev in sorted(glob.glob("/sys/class/drm/card*/device")):
        driver = os.path.basename(os.path.realpath(os.path.join(card_dev, "driver")))
        if driver != "amdgpu":
            continue
        bdf = os.path.basename(os.path.realpath(card_dev))
        try:
            with open(os.path.join(card_dev, "mem_info_vram_total")) as f:
                vram_mb = int(f.read().strip()) // 1048576
        except (OSError, ValueError):
            vram_mb = 0
        if vram_mb >= MIN_VRAM_MB:
            gpus.append({"bdf": bdf, "vram_mb": vram_mb})
    checks["gpus"] = gpus
    checks["gpu_count"] = len(gpus)
    return checks


def _which(name):
    try:
        return subprocess.run(["which", name], capture_output=True).returncode == 0
    except Exception:
        return False


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


class DownloadThread(QThread):
    progress = pyqtSignal(str)
    finished_dl = pyqtSignal(bool, str)

    def __init__(self, url, dest):
        super().__init__()
        self.url = url
        self.dest = dest

    def run(self):
        os.makedirs(os.path.dirname(self.dest), exist_ok=True)
        self.progress.emit(f"Downloading {os.path.basename(self.dest)}...")
        try:
            proc = subprocess.Popen(
                ["curl", "-L", "-o", self.dest, "--progress-bar", self.url],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )
            for line in proc.stdout:
                line = line.strip()
                if line:
                    self.progress.emit(line)
            proc.wait()
            if proc.returncode == 0 and os.path.isfile(self.dest):
                size_mb = os.path.getsize(self.dest) / 1048576
                self.finished_dl.emit(True, f"Downloaded {size_mb:.0f} MB")
            else:
                self.finished_dl.emit(False, "Download failed")
        except Exception as e:
            self.finished_dl.emit(False, str(e))


class BenchThread(QThread):
    log_line = pyqtSignal(str)
    result = pyqtSignal(int, float)  # gpu_id, tokens_per_sec
    finished_bench = pyqtSignal()

    def __init__(self, model_path, gpu_ids):
        super().__init__()
        self.model_path = model_path
        self.gpu_ids = gpu_ids
        self._stop = False
        self._env = os.environ.copy()

    def run(self):
        prompt = "Explain the theory of relativity in simple terms."
        for gid in self.gpu_ids:
            if self._stop:
                break
            self.log_line.emit(f"\n--- GPU {gid} ---")
            env = self._env.copy()
            env["GGML_VK_DEVICE"] = str(gid)
            try:
                outpath = os.path.join(REPO_ROOT, "results", f"llm_gpu{gid}.log")
                self.log_line.emit(f"Running inference on GPU {gid}...")
                r = subprocess.run(
                    ["bash", "-c",
                     f'{LLAMA_BIN} -m "{self.model_path}" '
                     f'-p "Explain the theory of relativity in simple terms." '
                     f'-n 128 -ngl 99 --single-turn '
                     f'> "{outpath}" 2>&1'],
                    env=env, timeout=300,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                with open(outpath, "r", errors="replace") as f:
                    stdout = f.read()
                tps = 0.0
                for line in stdout.replace("\r", "\n").split("\n"):
                    stripped = line.strip()
                    if stripped:
                        self.log_line.emit(stripped)
                    if "Generation:" in line and "t/s" in line:
                        try:
                            part = line.split("Generation:")[1].split("t/s")[0].strip()
                            tps = float(part)
                        except (ValueError, IndexError):
                            pass
                self.log_line.emit(f"GPU {gid}: {tps:.1f} tokens/sec {'PASS' if tps > 0 else 'FAIL'}")
                self.result.emit(gid, tps)
            except subprocess.TimeoutExpired:
                self.log_line.emit(f"[ERROR] GPU {gid}: timeout (300s)")
                self.result.emit(gid, 0.0)
            except Exception as e:
                self.log_line.emit(f"[ERROR] GPU {gid}: {e}")
                self.result.emit(gid, 0.0)
        self.finished_bench.emit()

    def stop(self):
        self._stop = True


class LlmPage(QWidget):
    def __init__(self):
        super().__init__()
        self._bench_thread = None
        self._dl_thread = None

        layout = QHBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(24)

        # --- Left: environment + controls ---
        left = QVBoxLayout()
        left.setSpacing(12)

        title = QLabel("AI MODEL TEST")
        title.setStyleSheet("color:#00d4ff; font-size:16px; font-weight:bold; letter-spacing:2px;")
        left.addWidget(title)

        # Environment status
        self._env_frame = QFrame()
        self._env_frame.setStyleSheet("background:#1c2a4a; border-radius:6px; padding:12px;")
        env_layout = QVBoxLayout(self._env_frame)
        env_layout.setSpacing(6)
        env_label = QLabel("ENVIRONMENT")
        env_label.setStyleSheet("color:#888; font-size:11px; font-weight:bold; letter-spacing:2px;")
        env_layout.addWidget(env_label)
        self._lbl_llama = QLabel()
        self._lbl_gpu = QLabel()
        self._lbl_model = QLabel()
        for lbl in [self._lbl_llama, self._lbl_gpu, self._lbl_model]:
            lbl.setStyleSheet("font-size:13px; padding:2px;")
            env_layout.addWidget(lbl)
        left.addWidget(self._env_frame)

        # Model controls
        model_label = QLabel("MODEL")
        model_label.setStyleSheet("color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px;")
        left.addWidget(model_label)

        self._combo_model = QComboBox()
        self._combo_model.setStyleSheet("""
            QComboBox { background:#1c2a4a; color:#e0e0e0; border:1px solid #444;
                        border-radius:4px; padding:8px; font-size:13px; }
        """)
        left.addWidget(self._combo_model)

        self._btn_download = QPushButton("Download Llama 3.1 8B Q4 (~4.5GB)")
        self._btn_download.setStyleSheet("""
            QPushButton { background:#3498db; color:#fff; border:none; border-radius:6px;
                          padding:10px; font-size:13px; font-weight:bold; }
            QPushButton:hover { background:#2980b9; }
            QPushButton:disabled { background:#333; color:#666; }
        """)
        self._btn_download.clicked.connect(self._download_model)
        left.addWidget(self._btn_download)

        self._lbl_dl_status = QLabel("")
        self._lbl_dl_status.setStyleSheet("color:#888; font-size:12px;")
        self._lbl_dl_status.setWordWrap(True)
        left.addWidget(self._lbl_dl_status)

        # GPU selection
        gpu_label = QLabel("GPU SELECTION")
        gpu_label.setStyleSheet("color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px;")
        left.addWidget(gpu_label)

        self._combo_gpu = QComboBox()
        self._combo_gpu.setStyleSheet("""
            QComboBox { background:#1c2a4a; color:#e0e0e0; border:1px solid #444;
                        border-radius:4px; padding:8px; font-size:13px; }
        """)
        left.addWidget(self._combo_gpu)

        # Start/Stop
        btn_row = QHBoxLayout()
        self._btn_start = QPushButton("START BENCH")
        self._btn_start.setFixedHeight(50)
        self._btn_start.setStyleSheet("""
            QPushButton { background:#2ed573; color:#111; border:none; border-radius:8px;
                          font-size:16px; font-weight:bold; }
            QPushButton:hover { background:#26c064; }
            QPushButton:disabled { background:#333; color:#666; }
        """)
        self._btn_start.clicked.connect(self._start_bench)

        self._btn_stop = QPushButton("STOP")
        self._btn_stop.setFixedHeight(50)
        self._btn_stop.setEnabled(False)
        self._btn_stop.setStyleSheet("""
            QPushButton { background:#ff4757; color:#fff; border:none; border-radius:8px;
                          font-size:16px; font-weight:bold; }
            QPushButton:hover { background:#e03e4a; }
            QPushButton:disabled { background:#333; color:#666; }
        """)
        self._btn_stop.clicked.connect(self._stop_bench)
        btn_row.addWidget(self._btn_start)
        btn_row.addWidget(self._btn_stop)
        left.addLayout(btn_row)

        left.addStretch()
        layout.addLayout(left, 1)

        # --- Right: results + log ---
        right = QVBoxLayout()
        right.setSpacing(12)

        result_label = QLabel("RESULTS")
        result_label.setStyleSheet("color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px;")
        right.addWidget(result_label)

        self._table = QTableWidget(0, 3)
        self._table.setHorizontalHeaderLabels(["GPU", "tokens/sec", "Status"])
        self._table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        self._table.setStyleSheet("""
            QTableWidget { background:#0d1117; color:#e0e0e0; border:1px solid #333;
                           gridline-color:#333; font-size:13px; }
            QHeaderView::section { background:#1c2a4a; color:#aaa; border:1px solid #333;
                                   padding:6px; font-weight:bold; }
        """)
        self._table.setFixedHeight(200)
        right.addWidget(self._table)

        log_label = QLabel("LOG")
        log_label.setStyleSheet("color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px;")
        right.addWidget(log_label)

        self._log = QTextEdit()
        self._log.setReadOnly(True)
        self._log.setStyleSheet("""
            QTextEdit { background:#0d1117; color:#aaa; border:1px solid #333;
                        border-radius:4px; font-family:monospace; font-size:11px; }
        """)
        right.addWidget(self._log)
        layout.addLayout(right, 2)

        self._refresh_env()

    def _refresh_env(self):
        env = _check_env()

        def status(ok, label_ok, label_fail):
            if ok:
                return f"<span style='color:#2ed573'>✓ {label_ok}</span>"
            return f"<span style='color:#ff4757'>✗ {label_fail}</span>"

        self._lbl_llama.setText(status(env["llama_cli"], "llama-cli ready (Vulkan)", "llama-cli not found — run deploy.sh --with-llm"))
        self._lbl_gpu.setText(status(env["gpu_count"] > 0, f"{env['gpu_count']} GPU(s) detected", "No amdgpu GPU found"))
        self._lbl_model.setText(status(len(env["models"]) > 0,
                                       f"{len(env['models'])} model(s) in models/",
                                       "No .gguf model — download or place in models/"))

        # Populate model combo
        self._combo_model.clear()
        for m in env["models"]:
            self._combo_model.addItem(os.path.basename(m), m)
        if not env["models"]:
            self._combo_model.addItem("(no model available)")

        # Populate GPU combo — only GPUs with enough VRAM
        self._combo_gpu.clear()
        self._combo_gpu.addItem("All GPUs (sequential)", "all")
        self._eligible_gpus = env.get("gpus", [])
        for i, g in enumerate(self._eligible_gpus):
            self._combo_gpu.addItem(f"GPU {i} [{g['bdf']}] {g['vram_mb']}MB", str(i))

        # Enable/disable start
        ready = env["llama_cli"] and env["gpu_count"] > 0 and len(env["models"]) > 0
        self._btn_start.setEnabled(ready)
        if not ready:
            self._btn_start.setToolTip("Fix environment issues above before running")

    def _download_model(self):
        if self._dl_thread and self._dl_thread.isRunning():
            return
        dest = os.path.join(MODELS_DIR, DEFAULT_MODEL_NAME)
        self._btn_download.setEnabled(False)
        self._lbl_dl_status.setText("Starting download...")
        self._dl_thread = DownloadThread(DEFAULT_MODEL_URL, dest)
        self._dl_thread.progress.connect(lambda s: self._lbl_dl_status.setText(s))
        self._dl_thread.finished_dl.connect(self._on_dl_done)
        self._dl_thread.start()

    def _on_dl_done(self, ok, msg):
        self._btn_download.setEnabled(True)
        if ok:
            self._lbl_dl_status.setText(f"✓ {msg}")
            self._lbl_dl_status.setStyleSheet("color:#2ed573; font-size:12px;")
        else:
            self._lbl_dl_status.setText(f"✗ {msg}")
            self._lbl_dl_status.setStyleSheet("color:#ff4757; font-size:12px;")
        self._refresh_env()

    def _start_bench(self):
        self._refresh_env()
        model_path = self._combo_model.currentData()
        if not model_path or not os.path.isfile(str(model_path)):
            self._log.append(f"[ERROR] No valid model selected: {model_path}")
            return
        gpu_sel = self._combo_gpu.currentData()

        env = _check_env()
        if gpu_sel == "all":
            gpu_ids = list(range(env["gpu_count"]))
        else:
            gpu_ids = [int(gpu_sel)]

        self._table.setRowCount(0)
        self._log.clear()
        self._btn_start.setEnabled(False)
        self._btn_stop.setEnabled(True)

        self._bench_thread = BenchThread(model_path, gpu_ids)
        self._bench_thread.log_line.connect(self._log.append)
        self._bench_thread.result.connect(self._on_result)
        self._bench_thread.finished_bench.connect(self._on_bench_done)
        self._bench_thread.start()

    def _stop_bench(self):
        if self._bench_thread:
            self._bench_thread.stop()

    def _on_result(self, gpu_id, tps):
        row = self._table.rowCount()
        self._table.insertRow(row)
        self._table.setItem(row, 0, QTableWidgetItem(f"GPU {gpu_id}"))
        self._table.setItem(row, 1, QTableWidgetItem(f"{tps:.1f}" if tps > 0 else "FAILED"))
        status = "PASS" if tps > 0 else "FAIL"
        item = QTableWidgetItem(status)
        if status == "PASS":
            item.setForeground(Qt.GlobalColor.green)
        else:
            item.setForeground(Qt.GlobalColor.red)
        self._table.setItem(row, 2, item)

    def _on_bench_done(self):
        self._btn_start.setEnabled(True)
        self._btn_stop.setEnabled(False)
        self._log.append("\n--- Benchmark complete ---")

    def on_sensor_data(self, data):
        pass
