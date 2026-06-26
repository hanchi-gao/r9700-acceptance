"""Top status bar showing live sensor summary."""
from PyQt6.QtWidgets import QWidget, QHBoxLayout, QLabel, QFrame
from PyQt6.QtCore import Qt


class _Gauge(QFrame):
    def __init__(self, title, unit="°C"):
        super().__init__()
        self.setStyleSheet("background:#16213e; border-radius:4px; padding:2px 8px;")
        lay = QHBoxLayout(self)
        lay.setContentsMargins(8, 2, 8, 2)
        lay.setSpacing(4)
        self._title = QLabel(title)
        self._title.setStyleSheet("color:#888; font-size:11px;")
        self._value = QLabel("--")
        self._value.setStyleSheet("color:#2ed573; font-size:16px; font-weight:bold;")
        self._unit = QLabel(unit)
        self._unit.setStyleSheet("color:#666; font-size:11px;")
        lay.addWidget(self._title)
        lay.addWidget(self._value)
        lay.addWidget(self._unit)

    def set_value(self, val, warn=None, fail=None):
        if val is None:
            self._value.setText("--")
            self._value.setStyleSheet("color:#666; font-size:16px; font-weight:bold;")
            return
        self._value.setText(f"{val:.1f}")
        if fail and val >= fail:
            color = "#ff4757"
        elif warn and val >= warn:
            color = "#ffa502"
        else:
            color = "#2ed573"
        self._value.setStyleSheet(f"color:{color}; font-size:16px; font-weight:bold;")

    def set_title(self, title):
        self._title.setText(title)


class TopBar(QWidget):
    def __init__(self):
        super().__init__()
        self.setFixedHeight(44)
        self.setStyleSheet("background:#0f1628; border-bottom:2px solid #00d4ff;")
        lay = QHBoxLayout(self)
        lay.setContentsMargins(12, 0, 12, 0)
        lay.setSpacing(16)

        self._gauges = {}
        for name, unit, warn, fail in [
            ("CPU", "°C", 85, 90),
            ("GPU Junc(max)", "°C", 95, 100),
            ("GPU VRAM(max)", "°C", 96, 100),
            ("GPU Power", "W", None, None),
            ("DRAM", "°C", None, None),
            ("NVMe", "°C", 70, 80),
        ]:
            g = _Gauge(name, unit)
            g._warn = warn
            g._fail = fail
            self._gauges[name] = g
            lay.addWidget(g)

        lay.addStretch()

    def update_data(self, data):
        # CPU
        cpu = data.get("cpu_tctl")
        g = self._gauges["CPU"]
        g.set_value(cpu, g._warn, g._fail)

        # DRAM — average all DRAM sensors
        dram_vals = [data[k] for k in data if k.startswith("dram_") and data[k] is not None]
        g = self._gauges["DRAM"]
        if dram_vals:
            g.set_value(sum(dram_vals) / len(dram_vals), g._warn, g._fail)
            g.set_title(f"DRAM({len(dram_vals)})")
        else:
            g.set_value(None)

        # NVMe
        nvme_vals = [data[k] for k in data if k.startswith("nvme_") and data[k] is not None]
        g = self._gauges["NVMe"]
        g.set_value(nvme_vals[0] if nvme_vals else None, g._warn, g._fail)

        # GPU — show max across all cards
        gpus = data.get("gpus", [])
        if gpus:
            junctions = [gpu["junction"] for gpu in gpus if gpu.get("junction") is not None]
            mems = [gpu["memory"] for gpu in gpus if gpu.get("memory") is not None]
            powers = [gpu["power_w"] for gpu in gpus if gpu.get("power_w") is not None]

            gj = self._gauges["GPU Junc(max)"]
            gj.set_value(max(junctions) if junctions else None, gj._warn, gj._fail)

            gm = self._gauges["GPU VRAM(max)"]
            gm.set_value(max(mems) if mems else None, gm._warn, gm._fail)

            gp = self._gauges["GPU Power"]
            gp.set_value(sum(powers) if powers else None, gp._warn, gp._fail)
            gp.set_title(f"GPU Power({len(powers)}卡)")
