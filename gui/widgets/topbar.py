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
            ("CPU", "°C", 85, 95),
            ("GPU Junction", "°C", 98, 103),
            ("GPU VRAM", "°C", 100, 104),
            ("GPU Power", "W", None, None),
            ("DRAM", "°C", None, None),
            ("NVMe", "°C", 75, 83),
        ]:
            g = _Gauge(name, unit)
            g._warn = warn
            g._fail = fail
            self._gauges[name] = g
            lay.addWidget(g)

        lay.addStretch()

    def update_data(self, data):
        cpu = data.get("cpu_tctl")
        g = self._gauges["CPU"]
        g.set_value(cpu, g._warn, g._fail)

        dram_keys = [k for k in data if k.startswith("dram_")]
        dram_val = data.get(dram_keys[0]) if dram_keys else None
        g = self._gauges["DRAM"]
        g.set_value(dram_val, g._warn, g._fail)

        nvme_keys = [k for k in data if k.startswith("nvme_")]
        nvme_val = data.get(nvme_keys[0]) if nvme_keys else None
        g = self._gauges["NVMe"]
        g.set_value(nvme_val, g._warn, g._fail)

        gpus = data.get("gpus", [])
        if gpus:
            junctions = [g["junction"] for g in gpus if g["junction"] is not None]
            mems = [g["memory"] for g in gpus if g["memory"] is not None]
            powers = [g["power_w"] for g in gpus if g["power_w"] is not None]
            gj = self._gauges["GPU Junction"]
            gj.set_value(max(junctions) if junctions else None, gj._warn, gj._fail)
            gm = self._gauges["GPU VRAM"]
            gm.set_value(max(mems) if mems else None, gm._warn, gm._fail)
            gp = self._gauges["GPU Power"]
            gp.set_value(sum(powers) if powers else None, gp._warn, gp._fail)
