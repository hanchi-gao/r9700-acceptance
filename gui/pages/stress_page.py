"""Stability Test page — component selection, Light/Full mode, start/stop."""
import glob
import os
import time

from PyQt6.QtWidgets import (
    QWidget, QHBoxLayout, QVBoxLayout, QLabel, QCheckBox,
    QPushButton, QSpinBox, QTextEdit, QFrame, QGroupBox, QGridLayout,
    QLineEdit,
)
from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QFont

from burnin import BurninThread


def _enumerate_gpus():
    """Return list of (index, bdf) for amdgpu devices, sorted by BDF."""
    bdfs = []
    for d in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        try:
            name = open(os.path.join(d, "name")).read().strip()
        except OSError:
            continue
        if name != "amdgpu":
            continue
        bdf = os.path.basename(os.path.realpath(os.path.join(d, "device")))
        bdfs.append(bdf)
    return [(i, bdf) for i, bdf in enumerate(sorted(set(bdfs)))]


class _ModeButton(QPushButton):
    STYLE_OFF = """
        QPushButton { background:#1c2a4a; color:#aaa; border:2px solid #333;
                      border-radius:8px; font-size:15px; font-weight:bold; padding:14px 28px; }
        QPushButton:hover { border-color:#00d4ff; }
    """
    STYLE_ON = """
        QPushButton { background:#00d4ff; color:#111; border:2px solid #00d4ff;
                      border-radius:8px; font-size:15px; font-weight:bold; padding:14px 28px; }
    """

    def __init__(self, text):
        super().__init__(text)
        self.setCheckable(True)
        self._update_style()
        self.toggled.connect(lambda: self._update_style())

    def _update_style(self):
        self.setStyleSheet(self.STYLE_ON if self.isChecked() else self.STYLE_OFF)


class StressPage(QWidget):
    def __init__(self):
        super().__init__()
        self._burnin = None
        self._duration = 1800
        self._timer = QTimer()
        self._timer.timeout.connect(self._tick)

        layout = QHBoxLayout(self)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(24)

        # --- Left: Components ---
        left = QVBoxLayout()
        left.setSpacing(12)
        comp_label = QLabel("COMPONENTS")
        comp_label.setStyleSheet("color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px;")
        left.addWidget(comp_label)

        chk_style = "QCheckBox { color:#ddd; font-size:14px; padding:4px 6px; } QCheckBox::indicator { width:16px; height:16px; }"
        sub_style = "QCheckBox { color:#aaa; font-size:12px; padding:2px 6px 2px 22px; } QCheckBox::indicator { width:14px; height:14px; }"

        # GPU section with per-card checkboxes
        self._chk_gpu = QCheckBox("GPU  (Vulkan VRAM burn)")
        self._chk_gpu.setChecked(True)
        self._chk_gpu.setStyleSheet(chk_style)
        left.addWidget(self._chk_gpu)

        self._gpu_cards = _enumerate_gpus()
        self._chk_gpu_cards = []
        for idx, bdf in self._gpu_cards:
            chk = QCheckBox(f"  GPU{idx}  [{bdf}]")
            chk.setChecked(True)
            chk.setStyleSheet(sub_style)
            left.addWidget(chk)
            self._chk_gpu_cards.append((idx, chk))

        self._chk_gpu.toggled.connect(self._on_gpu_master_toggled)

        self._chk_cpu = QCheckBox("CPU / RAM  (stress-ng)")
        self._chk_ssd = QCheckBox("SSD  (fio)")
        for chk in [self._chk_cpu, self._chk_ssd]:
            chk.setChecked(True)
            chk.setStyleSheet(chk_style)
            left.addWidget(chk)

        left.addSpacing(24)

        # Mode
        mode_label = QLabel("MODE")
        mode_label.setStyleSheet("color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px;")
        left.addWidget(mode_label)

        self._btn_light = _ModeButton("Light")
        self._btn_full = _ModeButton("Full")
        self._btn_full.setChecked(True)
        self._btn_light.clicked.connect(lambda: self._set_mode("light"))
        self._btn_full.clicked.connect(lambda: self._set_mode("full"))

        mode_row = QHBoxLayout()
        mode_row.addWidget(self._btn_light)
        mode_row.addWidget(self._btn_full)
        left.addLayout(mode_row)

        self._mode_info = QLabel()
        self._mode_info.setStyleSheet("color:#888; font-size:12px; padding:8px;")
        self._mode_info.setWordWrap(True)
        left.addWidget(self._mode_info)
        self._update_mode_info()

        left.addSpacing(16)

        # Duration
        dur_label = QLabel("DURATION")
        dur_label.setStyleSheet("color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px;")
        left.addWidget(dur_label)

        dur_row = QHBoxLayout()
        self._dur_spin = QSpinBox()
        self._dur_spin.setRange(1, 480)
        self._dur_spin.setValue(30)
        self._dur_spin.setStyleSheet("""
            QSpinBox { background:#1c2a4a; color:#e0e0e0; border:1px solid #444;
                       border-radius:4px; padding:8px; font-size:16px; min-width:80px; }
        """)
        dur_unit = QLabel("min")
        dur_unit.setStyleSheet("color:#aaa; font-size:15px; padding-left:6px;")
        dur_row.addWidget(self._dur_spin)
        dur_row.addWidget(dur_unit)
        dur_row.addStretch()
        left.addLayout(dur_row)

        left.addSpacing(20)

        # --- Acceptance mode toggle ---
        sep = QFrame()
        sep.setFrameShape(QFrame.Shape.HLine)
        sep.setStyleSheet("color:#333;")
        left.addWidget(sep)

        self._chk_acceptance = QCheckBox("完整驗收模式")
        self._chk_acceptance.setStyleSheet(
            "QCheckBox { color:#ffa502; font-size:14px; font-weight:bold; padding:6px; }"
            "QCheckBox::indicator { width:18px; height:18px; }"
        )
        left.addWidget(self._chk_acceptance)

        self._serial_row = QWidget()
        serial_layout = QHBoxLayout(self._serial_row)
        serial_layout.setContentsMargins(0, 0, 0, 0)
        serial_lbl = QLabel("序號 SN:")
        serial_lbl.setStyleSheet("color:#aaa; font-size:13px;")
        self._serial_edit = QLineEdit()
        self._serial_edit.setPlaceholderText("SN12345")
        self._serial_edit.setStyleSheet(
            "QLineEdit { background:#1c2a4a; color:#e0e0e0; border:1px solid #555;"
            " border-radius:4px; padding:6px; font-size:14px; }"
        )
        serial_layout.addWidget(serial_lbl)
        serial_layout.addWidget(self._serial_edit)
        self._serial_row.setVisible(False)
        left.addWidget(self._serial_row)

        self._acceptance_info = QLabel(
            "包含 preflight → inventory → baseline\n→ 燒機 → postcheck → report"
        )
        self._acceptance_info.setStyleSheet("color:#888; font-size:11px; padding:4px 6px;")
        self._acceptance_info.setVisible(False)
        left.addWidget(self._acceptance_info)

        self._chk_acceptance.toggled.connect(self._on_acceptance_toggled)

        left.addStretch()
        layout.addLayout(left, 1)

        # --- Center: Start/Stop + Timer ---
        center = QVBoxLayout()
        center.setAlignment(Qt.AlignmentFlag.AlignCenter)
        center.setSpacing(20)

        self._btn_start = QPushButton("START")
        self._btn_start.setFixedSize(200, 60)
        self._btn_start.setStyleSheet("""
            QPushButton { background:#2ed573; color:#111; border:none; border-radius:10px;
                          font-size:22px; font-weight:bold; }
            QPushButton:hover { background:#26c064; }
            QPushButton:disabled { background:#333; color:#666; }
        """)
        self._btn_start.clicked.connect(self._start)
        center.addWidget(self._btn_start, 0, Qt.AlignmentFlag.AlignCenter)

        self._btn_stop = QPushButton("STOP")
        self._btn_stop.setFixedSize(200, 60)
        self._btn_stop.setEnabled(False)
        self._btn_stop.setStyleSheet("""
            QPushButton { background:#ff4757; color:#fff; border:none; border-radius:10px;
                          font-size:22px; font-weight:bold; }
            QPushButton:hover { background:#e03e4a; }
            QPushButton:disabled { background:#333; color:#666; }
        """)
        self._btn_stop.clicked.connect(self._stop)
        center.addWidget(self._btn_stop, 0, Qt.AlignmentFlag.AlignCenter)

        self._lbl_timer = QLabel("00:00:00")
        self._lbl_timer.setStyleSheet("color:#00d4ff; font-size:36px; font-weight:bold;")
        self._lbl_timer.setAlignment(Qt.AlignmentFlag.AlignCenter)
        center.addWidget(self._lbl_timer)

        self._lbl_total = QLabel("")
        self._lbl_total.setStyleSheet("color:#888; font-size:14px;")
        self._lbl_total.setAlignment(Qt.AlignmentFlag.AlignCenter)
        center.addWidget(self._lbl_total)

        self._lbl_verdict = QLabel("")
        self._lbl_verdict.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._lbl_verdict.setStyleSheet("font-size:24px; font-weight:bold; padding:12px;")
        center.addWidget(self._lbl_verdict)

        self._lbl_results_path = QLabel("")
        self._lbl_results_path.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._lbl_results_path.setStyleSheet("color:#888; font-size:11px;")
        self._lbl_results_path.setWordWrap(True)
        center.addWidget(self._lbl_results_path)

        center.addStretch()
        layout.addLayout(center, 1)

        # --- Right: Status log ---
        right = QVBoxLayout()
        log_label = QLabel("STATUS LOG")
        log_label.setStyleSheet("color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px;")
        right.addWidget(log_label)

        self._log = QTextEdit()
        self._log.setReadOnly(True)
        self._log.setStyleSheet("""
            QTextEdit { background:#0d1117; color:#aaa; border:1px solid #333;
                        border-radius:4px; font-family:monospace; font-size:12px; }
        """)
        right.addWidget(self._log)
        layout.addLayout(right, 1)

    def _on_acceptance_toggled(self, checked):
        self._serial_row.setVisible(checked)
        self._acceptance_info.setVisible(checked)
        # Full acceptance always burns all GPUs — disable per-card selection
        for _, chk in self._chk_gpu_cards:
            chk.setEnabled(not checked)
        if checked:
            self._chk_gpu.setChecked(True)
            for _, chk in self._chk_gpu_cards:
                chk.setChecked(True)

    def _on_gpu_master_toggled(self, checked):
        for _, chk in self._chk_gpu_cards:
            chk.setEnabled(checked)
            chk.setChecked(checked)

    def _get_gpu_ids(self):
        """Return comma-separated GPU indices to burn, or '' for all."""
        if not self._chk_gpu.isChecked():
            return ""
        selected = [str(idx) for idx, chk in self._chk_gpu_cards if chk.isChecked()]
        if len(selected) == len(self._chk_gpu_cards):
            return ""  # all selected → no filter needed
        return ",".join(selected)

    def _set_mode(self, mode):
        self._btn_light.setChecked(mode == "light")
        self._btn_full.setChecked(mode == "full")
        self._update_mode_info()

    def _update_mode_info(self):
        if self._btn_light.isChecked():
            self._mode_info.setText(
                "Light mode:\n"
                "• GPU: 50% VRAM fill\n"
                "• CPU: half cores, no memtester\n"
                "• SSD: iodepth=8, numjobs=2"
            )
        else:
            self._mode_info.setText(
                "Full mode:\n"
                "• GPU: 90% VRAM fill (~300W)\n"
                "• CPU: all cores + memtester\n"
                "• SSD: iodepth=32, numjobs=4"
            )

    def _get_components(self):
        comps = []
        if self._chk_gpu.isChecked(): comps.append("gpu")
        if self._chk_cpu.isChecked(): comps.append("cpu")
        if self._chk_ssd.isChecked(): comps.append("ssd")
        return ",".join(comps) if len(comps) < 3 else "all"

    def _start(self):
        comps = self._get_components()
        if not comps:
            return
        mode = "light" if self._btn_light.isChecked() else "full"
        duration = self._dur_spin.value() * 60
        self._duration = duration

        self._lbl_verdict.setText("")
        self._log.clear()
        self._btn_start.setEnabled(False)
        self._btn_stop.setEnabled(True)
        self._lbl_total.setText(f"/ {self._dur_spin.value()}:00")

        full_acceptance = self._chk_acceptance.isChecked()
        serial = self._serial_edit.text().strip()
        if full_acceptance and not serial:
            self._lbl_verdict.setText("請輸入序號")
            self._lbl_verdict.setStyleSheet("color:#ffa502; font-size:18px; font-weight:bold; padding:12px;")
            self._btn_start.setEnabled(True)
            self._btn_stop.setEnabled(False)
            return

        gpu_ids = self._get_gpu_ids()
        self._burnin = BurninThread(comps, duration, mode, gpu_ids, full_acceptance, serial)
        self._lbl_results_path.setText(f"Results → {self._burnin.results_dir}")
        self._burnin.log_line.connect(self._append_log)
        self._burnin.stopped.connect(self._on_stopped)
        self._burnin.finished_burnin.connect(self._on_finished)
        self._burnin.start()
        self._timer.start(500)

    def _stop(self):
        if self._burnin:
            self._burnin.stop()
            self._btn_stop.setEnabled(False)

    def force_stop(self):
        if self._burnin and self._burnin.isRunning():
            self._burnin.stop()
            self._burnin.wait(5000)

    def _append_log(self, line):
        self._log.append(line)

    def _on_stopped(self):
        self._timer.stop()
        self._btn_start.setEnabled(True)
        self._btn_stop.setEnabled(False)

    def _on_finished(self, rc):
        if rc == 0:
            self._lbl_verdict.setText("PASS")
            self._lbl_verdict.setStyleSheet("color:#2ed573; font-size:24px; font-weight:bold; padding:12px;")
        elif rc == -1 and not self._btn_stop.isEnabled():
            self._lbl_verdict.setText("STOPPED")
            self._lbl_verdict.setStyleSheet("color:#ffa502; font-size:24px; font-weight:bold; padding:12px;")
        else:
            self._lbl_verdict.setText("FAIL")
            self._lbl_verdict.setStyleSheet("color:#ff4757; font-size:24px; font-weight:bold; padding:12px;")

    def _tick(self):
        if self._burnin and self._burnin._start_time:
            elapsed = min(int(self._burnin.elapsed), self._duration)
            h, m, s = elapsed // 3600, (elapsed % 3600) // 60, elapsed % 60
            self._lbl_timer.setText(f"{h:02d}:{m:02d}:{s:02d}")

    def on_sensor_data(self, data):
        pass
