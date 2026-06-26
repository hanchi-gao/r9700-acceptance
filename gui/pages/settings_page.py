"""Settings page — edit lib/thresholds.sh and expected_config.yaml via GUI."""
import os
import re

from PyQt6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel, QPushButton,
    QSpinBox, QScrollArea, QFrame, QGridLayout,
)
from PyQt6.QtCore import Qt

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
THRESHOLDS_FILE = os.path.join(REPO_ROOT, "lib", "thresholds.sh")
CONFIG_FILE = os.path.join(REPO_ROOT, "expected_config.yaml")


# ---------------------------------------------------------------------------
# thresholds.sh helpers
# ---------------------------------------------------------------------------

def _read_thresholds():
    vals = {}
    try:
        with open(THRESHOLDS_FILE) as f:
            for line in f:
                m = re.match(r'^([A-Z_]+)=(\d+)', line.strip())
                if m:
                    vals[m.group(1)] = int(m.group(2))
    except OSError:
        pass
    return vals


def _write_threshold(key, value):
    try:
        with open(THRESHOLDS_FILE, "r") as f:
            content = f.read()
        new_content = re.sub(
            rf'^({re.escape(key)})=\d+',
            rf'\g<1>={value}',
            content, flags=re.MULTILINE,
        )
        with open(THRESHOLDS_FILE, "w") as f:
            f.write(new_content)
        return True
    except OSError as e:
        return str(e)


# ---------------------------------------------------------------------------
# expected_config.yaml helpers — section-aware integer read/write
# ---------------------------------------------------------------------------

def _read_yaml_int(section, key):
    """Read an integer `key` from the first matching `section:` block."""
    try:
        with open(CONFIG_FILE) as f:
            lines = f.readlines()
    except OSError:
        return None
    in_section = False
    section_indent = None
    for line in lines:
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if re.match(rf'^{re.escape(section)}:', line):
            in_section = True
            section_indent = indent
            continue
        if in_section:
            # leave section when we hit another top-level key
            if section_indent is not None and indent <= section_indent and stripped and not stripped.startswith('#'):
                break
            m = re.match(rf'^\s+{re.escape(key)}:\s*(\d+)', line)
            if m:
                return int(m.group(1))
    return None


def _write_yaml_int(section, key, value):
    """Replace the integer value of `key` inside `section:` block."""
    try:
        with open(CONFIG_FILE, "r") as f:
            lines = f.readlines()
    except OSError as e:
        return str(e)

    in_section = False
    section_indent = None
    new_lines = []
    replaced = False
    for line in lines:
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if re.match(rf'^{re.escape(section)}:', line):
            in_section = True
            section_indent = indent
            new_lines.append(line)
            continue
        if in_section and not replaced:
            if section_indent is not None and indent <= section_indent and stripped and not stripped.startswith('#'):
                in_section = False
            else:
                m = re.match(rf'^(\s+{re.escape(key)}:\s*)\d+', line)
                if m:
                    new_lines.append(f"{m.group(1)}{value}\n")
                    replaced = True
                    continue
        new_lines.append(line)

    if not replaced:
        return f"key '{section}.{key}' not found in {CONFIG_FILE}"
    try:
        with open(CONFIG_FILE, "w") as f:
            f.writelines(new_lines)
        return True
    except OSError as e:
        return str(e)


# ---------------------------------------------------------------------------
# Parameter definitions
# ---------------------------------------------------------------------------
# thresholds.sh params: (key, label, unit, min, max, step)
THRESHOLD_GROUPS = [
    ("硬體規格", []),          # placeholder — yaml params added separately
    ("GPU 接合溫度 (Junction)", [
        ("GPU_JUNCTION_WARN_C",      "WARN",       "°C",    60, 110,   1),
        ("GPU_JUNCTION_FAIL_C",      "FAIL",       "°C",    60, 110,   1),
    ]),
    ("GPU 記憶體溫度 (VRAM / GDDR6)", [
        ("GPU_MEMORY_WARN_C",        "WARN",       "°C",    60, 110,   1),
        ("GPU_MEMORY_FAIL_C",        "FAIL",       "°C",    60, 110,   1),
    ]),
    ("CPU 溫度 (Tctl)", [
        ("CPU_TCTL_WARN_C",          "WARN",       "°C",    50, 105,   1),
        ("CPU_TCTL_FAIL_C",          "FAIL",       "°C",    50, 105,   1),
    ]),
    ("NVMe 溫度", [
        ("SSD_NVME_TEMP_WARN_C",     "WARN",       "°C",    40,  95,   1),
        ("SSD_NVME_TEMP_FAIL_C",     "FAIL",       "°C",    40,  95,   1),
    ]),
    ("SSD 吞吐量下限", [
        ("SSD_SEQ_READ_FLOOR_MBPS",  "循序讀取",  "MB/s", 1000, 20000, 100),
        ("SSD_SEQ_WRITE_FLOOR_MBPS", "循序寫入",  "MB/s", 1000, 20000, 100),
    ]),
    ("LLM 推理", [
        ("LLM_TOKENS_PER_SEC_FLOOR", "tokens/sec 下限", "t/s", 0, 1000, 1),
    ]),
]

# yaml params: (section, key, label, unit, min, max, step)
YAML_PARAMS = [
    ("gpu",     "count",         "GPU 數量",       "張",   1,   16,   1),
    ("storage", "nvme_count",    "NVMe 數量",      "個",   1,   16,   1),
    ("memory",  "total_gb_min",  "RAM 最低容量",   "GB",   1, 4096,   8),
]

_HDR  = "color:#00d4ff; font-size:13px; font-weight:bold; letter-spacing:2px; padding:8px 0 4px 0;"
_LBL  = "color:#ccc; font-size:13px;"
_UNIT = "color:#888; font-size:12px; padding-left:4px;"
_SPIN = """
    QSpinBox {
        background:#1c2a4a; color:#e0e0e0; border:1px solid #444;
        border-radius:4px; padding:5px 8px; font-size:14px; min-width:90px;
    }
    QSpinBox:focus { border-color:#00d4ff; }
"""


class SettingsPage(QWidget):
    def __init__(self):
        super().__init__()
        self._spinboxes = {}       # threshold key  -> QSpinBox
        self._yaml_spinboxes = {}  # (section, key) -> QSpinBox
        self._setup_ui()
        self._load()

    def _setup_ui(self):
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)

        # --- Header bar ---
        hdr_bar = QWidget()
        hdr_bar.setStyleSheet("background:#0d1117; border-bottom:1px solid #333;")
        hdr_layout = QHBoxLayout(hdr_bar)
        hdr_layout.setContentsMargins(24, 12, 24, 12)
        title = QLabel("THRESHOLD SETTINGS")
        title.setStyleSheet("color:#00d4ff; font-size:16px; font-weight:bold; letter-spacing:3px;")
        hdr_layout.addWidget(title)
        hdr_layout.addStretch()

        self._lbl_status = QLabel("")
        self._lbl_status.setStyleSheet("font-size:13px; font-weight:bold;")
        hdr_layout.addWidget(self._lbl_status)

        self._btn_reload = QPushButton("重新載入")
        self._btn_reload.setFixedWidth(90)
        self._btn_reload.setStyleSheet(
            "QPushButton { background:#1c2a4a; color:#aaa; border:1px solid #444;"
            " border-radius:4px; padding:6px 12px; font-size:12px; }"
            "QPushButton:hover { border-color:#00d4ff; color:#00d4ff; }"
        )
        self._btn_reload.clicked.connect(self._load)
        hdr_layout.addWidget(self._btn_reload)

        self._btn_save = QPushButton("儲存")
        self._btn_save.setFixedWidth(80)
        self._btn_save.setStyleSheet(
            "QPushButton { background:#00d4ff; color:#111; border:none;"
            " border-radius:4px; padding:6px 12px; font-size:13px; font-weight:bold; }"
            "QPushButton:hover { background:#00bfe8; }"
        )
        self._btn_save.clicked.connect(self._save)
        hdr_layout.addWidget(self._btn_save)

        outer.addWidget(hdr_bar)

        # --- Scrollable content ---
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setStyleSheet("QScrollArea { border:none; background:#1a1a2e; }")

        content = QWidget()
        content.setStyleSheet("background:#1a1a2e;")
        grid = QGridLayout(content)
        grid.setContentsMargins(32, 24, 32, 32)
        grid.setVerticalSpacing(8)
        grid.setHorizontalSpacing(24)
        grid.setColumnStretch(3, 1)

        row = 0

        def _sep():
            nonlocal row
            s = QFrame()
            s.setFrameShape(QFrame.Shape.HLine)
            s.setStyleSheet("color:#2a3a5a; margin:8px 0;")
            grid.addWidget(s, row, 0, 1, 4)
            row += 1

        def _hdr(text):
            nonlocal row
            lbl = QLabel(text)
            lbl.setStyleSheet(_HDR)
            grid.addWidget(lbl, row, 0, 1, 4)
            row += 1

        def _row(label, spin, unit):
            nonlocal row
            l = QLabel(label)
            l.setStyleSheet(_LBL)
            l.setFixedWidth(160)
            u = QLabel(unit)
            u.setStyleSheet(_UNIT)
            grid.addWidget(l,    row, 0)
            grid.addWidget(spin, row, 1)
            grid.addWidget(u,    row, 2)
            row += 1

        # --- Hardware spec (yaml) ---
        _hdr("硬體規格")
        for section, key, label, unit, mn, mx, step in YAML_PARAMS:
            spin = QSpinBox()
            spin.setRange(mn, mx)
            spin.setSingleStep(step)
            spin.setStyleSheet(_SPIN)
            self._yaml_spinboxes[(section, key)] = spin
            _row(label, spin, unit)

        # --- Threshold groups ---
        for group_title, params in THRESHOLD_GROUPS:
            if group_title == "硬體規格":
                continue  # already rendered above
            _sep()
            _hdr(group_title)
            for key, label, unit, mn, mx, step in params:
                spin = QSpinBox()
                spin.setRange(mn, mx)
                spin.setSingleStep(step)
                spin.setStyleSheet(_SPIN)
                self._spinboxes[key] = spin
                _row(label, spin, unit)

        scroll.setWidget(content)
        outer.addWidget(scroll)

    def _load(self):
        vals = _read_thresholds()
        for key, spin in self._spinboxes.items():
            if key in vals:
                spin.setValue(vals[key])
        for (section, key), spin in self._yaml_spinboxes.items():
            v = _read_yaml_int(section, key)
            if v is not None:
                spin.setValue(v)
        self._set_status("", "")

    def _save(self):
        errors = []
        for key, spin in self._spinboxes.items():
            r = _write_threshold(key, spin.value())
            if r is not True:
                errors.append(f"{key}: {r}")
        for (section, key), spin in self._yaml_spinboxes.items():
            r = _write_yaml_int(section, key, spin.value())
            if r is not True:
                errors.append(f"{section}.{key}: {r}")
        if errors:
            self._set_status("儲存失敗: " + "; ".join(errors), "#ff4757")
        else:
            self._set_status("已儲存", "#2ed573")

    def _set_status(self, msg, color):
        self._lbl_status.setText(msg)
        self._lbl_status.setStyleSheet(
            f"font-size:13px; font-weight:bold; color:{color}; padding-right:12px;"
        )
