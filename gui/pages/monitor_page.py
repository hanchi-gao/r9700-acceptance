"""Monitoring page — sensor checklist + individual chart cards, 2 per row."""
import re
import time
from collections import deque

import pyqtgraph as pg
from PyQt6.QtWidgets import (
    QWidget, QHBoxLayout, QVBoxLayout, QLabel, QCheckBox,
    QPushButton, QScrollArea, QFrame, QGridLayout,
)
from PyQt6.QtCore import Qt

from thresholds import THRESHOLDS, COLORS

MAX_POINTS = 900


class _SensorCard(QFrame):
    """Individual sensor card: title + live value + mini chart."""

    def __init__(self, key, label, color, warn=None, fail=None, unit=""):
        super().__init__()
        self.key = key
        self._warn = warn
        self._fail = fail
        self._unit = unit
        self._color = color
        self.times = deque(maxlen=MAX_POINTS)
        self.values = deque(maxlen=MAX_POINTS)

        self.setStyleSheet(f"background:#1c2a4a; border:1px solid #2a3a5a; border-radius:6px;")
        self.setMinimumHeight(200)

        lay = QVBoxLayout(self)
        lay.setContentsMargins(10, 8, 10, 6)
        lay.setSpacing(4)

        header = QHBoxLayout()
        self._lbl_title = QLabel(label)
        self._lbl_title.setStyleSheet(f"color:{color}; font-size:12px; font-weight:bold; border:none;")
        header.addWidget(self._lbl_title)
        header.addStretch()
        self._lbl_value = QLabel("--")
        self._lbl_value.setStyleSheet("color:#2ed573; font-size:20px; font-weight:bold; border:none;")
        header.addWidget(self._lbl_value)
        if unit:
            u = QLabel(unit)
            u.setStyleSheet("color:#666; font-size:11px; border:none;")
            header.addWidget(u)
        lay.addLayout(header)

        pg.setConfigOptions(antialias=True)
        self._plot = pg.PlotWidget(background="#0d1117")
        self._plot.setMouseEnabled(x=False, y=False)
        self._plot.hideButtons()
        self._plot.getPlotItem().hideAxis("bottom")
        self._plot.getPlotItem().hideAxis("left")
        self._plot.showGrid(y=True, alpha=0.1)
        self._plot.setMinimumHeight(120)
        self._curve = self._plot.plot(pen=pg.mkPen(color, width=2))

        if warn is not None:
            self._plot.addLine(y=warn, pen=pg.mkPen("#ffa502", width=1, style=pg.QtCore.Qt.PenStyle.DashLine))
        if fail is not None:
            self._plot.addLine(y=fail, pen=pg.mkPen("#ff4757", width=1, style=pg.QtCore.Qt.PenStyle.DashLine))

        lay.addWidget(self._plot)

    def append(self, t, v):
        self.times.append(t)
        self.values.append(v)
        self._lbl_value.setText(f"{v:.1f}")
        if self._fail and v >= self._fail:
            self._lbl_value.setStyleSheet("color:#ff4757; font-size:20px; font-weight:bold; border:none;")
        elif self._warn and v >= self._warn:
            self._lbl_value.setStyleSheet("color:#ffa502; font-size:20px; font-weight:bold; border:none;")
        else:
            self._lbl_value.setStyleSheet("color:#2ed573; font-size:20px; font-weight:bold; border:none;")

    def refresh_plot(self):
        if len(self.times) > 0:
            self._curve.setData(list(self.times), list(self.values))


class MonitorPage(QWidget):
    def __init__(self):
        super().__init__()
        self._cards = {}            # key -> _SensorCard
        self._checkboxes = {}       # key -> QCheckBox
        self._card_order = []       # keys in insertion order
        self._group_layouts = {}    # group name -> QVBoxLayout of that group container
        self._field_colors = {}     # field-type -> color (shared across GPU groups)
        self._t0 = None
        self._color_idx = 0

        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # --- Left: sensor checklist ---
        left_frame = QFrame()
        left_frame.setFixedWidth(220)
        left_frame.setStyleSheet("background:#0f1628; border-right:1px solid #333;")
        left_layout = QVBoxLayout(left_frame)
        left_layout.setContentsMargins(12, 12, 12, 12)
        left_layout.setSpacing(4)

        hdr = QLabel("SENSORS")
        hdr.setStyleSheet("color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px;")
        left_layout.addWidget(hdr)

        btn_row = QHBoxLayout()
        btn_all = QPushButton("Select All")
        btn_none = QPushButton("Clear All")
        for btn in [btn_all, btn_none]:
            btn.setStyleSheet("QPushButton{color:#aaa;background:#1c2a4a;border:1px solid #444;border-radius:4px;padding:4px 10px;font-size:11px;} QPushButton:hover{border-color:#00d4ff;}")
        btn_all.clicked.connect(self._select_all)
        btn_none.clicked.connect(self._clear_all)
        btn_row.addWidget(btn_all)
        btn_row.addWidget(btn_none)
        left_layout.addLayout(btn_row)

        scroll_left = QScrollArea()
        scroll_left.setWidgetResizable(True)
        scroll_left.setStyleSheet("QScrollArea{border:none;background:transparent;}")
        self._checklist_widget = QWidget()
        self._checklist_layout = QVBoxLayout(self._checklist_widget)
        self._checklist_layout.setContentsMargins(0, 8, 0, 8)
        self._checklist_layout.setSpacing(2)
        self._checklist_layout.addStretch()
        scroll_left.setWidget(self._checklist_widget)
        left_layout.addWidget(scroll_left)
        layout.addWidget(left_frame)

        # --- Right: scrollable grid of sensor cards ---
        scroll_right = QScrollArea()
        scroll_right.setWidgetResizable(True)
        scroll_right.setStyleSheet("QScrollArea{border:none; background:#1a1a2e;}")
        self._grid_widget = QWidget()
        self._grid_widget.setStyleSheet("background:#1a1a2e;")
        self._grid_layout = QGridLayout(self._grid_widget)
        self._grid_layout.setContentsMargins(16, 16, 16, 16)
        self._grid_layout.setSpacing(12)
        self._grid_layout.setColumnStretch(0, 1)
        self._grid_layout.setColumnStretch(1, 1)
        scroll_right.setWidget(self._grid_widget)
        layout.addWidget(scroll_right, 1)

    def _next_color(self):
        c = COLORS[self._color_idx % len(COLORS)]
        self._color_idx += 1
        return c

    def _color_for(self, key):
        # Strip GPU/DRAM/NVMe index so same field type shares a color across groups.
        # gpu0_junction -> junction, gpu2_vram_pct -> vram_pct, nvme_0 -> nvme
        field = re.sub(r'^gpu\d+_', '', key)
        field = re.sub(r'^(nvme|dram)_\d+$', r'\1', field)
        if field not in self._field_colors:
            self._field_colors[field] = self._next_color()
        return self._field_colors[field]

    def _get_thresholds(self, key):
        if "junction" in key:
            t = THRESHOLDS["gpu_junction"]
        elif "memory" in key and "gpu" in key:
            t = THRESHOLDS["gpu_memory"]
        elif "cpu_tctl" in key:
            t = THRESHOLDS["cpu_tctl"]
        elif "cpu_tccd" in key:
            t = THRESHOLDS["cpu_tccd1"]
        elif "nvme" in key:
            t = THRESHOLDS["nvme"]
        elif "power" in key:
            t = THRESHOLDS["gpu_power"]
        else:
            t = {"warn": None, "fail": None, "unit": ""}
        return t

    def _get_unit(self, key):
        if "power" in key:
            return "W"
        if "fan" in key or "rpm" in key:
            return "RPM"
        if "vram_pct" in key:
            return "%"
        return "°C"

    def _ensure_group(self, group):
        """Create a group container if not yet present; return its inner QVBoxLayout."""
        if group in self._group_layouts:
            return self._group_layouts[group]
        # Remove trailing stretch from main layout
        last = self._checklist_layout.takeAt(self._checklist_layout.count() - 1)
        # Header label
        hdr = QLabel(group)
        hdr.setStyleSheet("color:#00d4ff; font-size:11px; font-weight:bold; "
                          "letter-spacing:1px; padding:8px 0 2px 0;")
        self._checklist_layout.addWidget(hdr)
        # Inner container for this group's checkboxes
        container = QWidget()
        inner = QVBoxLayout(container)
        inner.setContentsMargins(0, 0, 0, 0)
        inner.setSpacing(2)
        self._checklist_layout.addWidget(container)
        self._checklist_layout.addStretch()
        self._group_layouts[group] = inner
        return inner

    def _ensure_sensor(self, key, label, group):
        if key in self._cards:
            return
        color = self._color_for(key)
        t = self._get_thresholds(key)
        unit = self._get_unit(key)
        card = _SensorCard(key, label, color, t.get("warn"), t.get("fail"), unit)
        card.setVisible(False)
        self._cards[key] = card
        self._card_order.append(key)

        inner = self._ensure_group(group)
        chk = QCheckBox(label)
        chk.setStyleSheet(f"QCheckBox{{color:{color};font-size:12px;padding:2px;}} "
                          f"QCheckBox::indicator{{width:14px;height:14px;}}")
        chk.toggled.connect(lambda checked, k=key: self._toggle_card(k, checked))
        self._checkboxes[key] = chk
        inner.addWidget(chk)

    def _rebuild_grid(self):
        while self._grid_layout.count():
            item = self._grid_layout.takeAt(0)
            if item.widget():
                item.widget().setParent(None)

        row, col = 0, 0
        for key in self._card_order:
            card = self._cards[key]
            chk = self._checkboxes.get(key)
            if chk and chk.isChecked():
                card.setVisible(True)
                self._grid_layout.addWidget(card, row, col)
                col += 1
                if col >= 2:
                    col = 0
                    row += 1
            else:
                card.setVisible(False)

    def _toggle_card(self, key, checked):
        self._rebuild_grid()

    def _select_all(self):
        for chk in self._checkboxes.values():
            chk.blockSignals(True)
            chk.setChecked(True)
            chk.blockSignals(False)
        self._rebuild_grid()

    def _clear_all(self):
        for chk in self._checkboxes.values():
            chk.blockSignals(True)
            chk.setChecked(False)
            chk.blockSignals(False)
        self._rebuild_grid()

    def on_sensor_data(self, data):
        ts = data.get("timestamp", time.time())
        if self._t0 is None:
            self._t0 = ts
        t = ts - self._t0

        for g in data.get("gpus", []):
            gid = g.get("id", "?")
            bdf = g.get("bdf", "")
            prefix = f"gpu{gid}"
            group = f"GPU{gid} [{bdf}]" if bdf else f"GPU{gid}"

            # Always register in fixed order so checklist is consistent across GPUs.
            for field, label_suffix in [
                ("junction", "Junction"), ("memory", "VRAM Temp"),
                ("edge", "Edge"), ("power_w", "Power"),
                ("fan_rpm", "Fan RPM"),
            ]:
                key = f"{prefix}_{field}"
                self._ensure_sensor(key, f"GPU{gid} {label_suffix}", group)
                val = g.get(field)
                if val is not None:
                    self._cards[key].append(t, val)

            key = f"{prefix}_vram_pct"
            self._ensure_sensor(key, f"GPU{gid} VRAM %", group)
            used = g.get("vram_used_mb")
            total = g.get("vram_total_mb")
            if used and total:
                self._cards[key].append(t, round(used / total * 100, 1))

        for field in ["cpu_tctl", "cpu_tccd1"]:
            val = data.get(field)
            if val is not None:
                label = "CPU Tctl" if "tctl" in field else "CPU Tccd1"
                self._ensure_sensor(field, label, "CPU")
                self._cards[field].append(t, val)

        for key in sorted(k for k in data if k.startswith("dram_")):
            val = data[key]
            if val is not None:
                idx = key.split("_")[1]
                self._ensure_sensor(key, f"DRAM {idx}", "DRAM")
                self._cards[key].append(t, val)

        for key in sorted(k for k in data if k.startswith("nvme_")):
            val = data[key]
            if val is not None:
                idx = key.split("_")[1]
                self._ensure_sensor(key, f"NVMe {idx}", "NVMe")
                self._cards[key].append(t, val)

        for key, card in self._cards.items():
            if card.isVisible():
                card.refresh_plot()
