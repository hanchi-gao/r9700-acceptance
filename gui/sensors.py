"""Unified sensor reader + QThread for periodic polling.
Reads all data from sysfs hwmon — no ROCm or rocm-smi needed.
"""
import os
import glob
import time

from PyQt6.QtCore import QThread, pyqtSignal


def _read_hwmon(name_match, label_map):
    result = {v: None for v in label_map.values()}
    for d in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            with open(os.path.join(d, "name")) as f:
                if f.read().strip() != name_match:
                    continue
        except OSError:
            continue
        for inp in glob.glob(os.path.join(d, "temp*_input")):
            label_file = inp.replace("_input", "_label")
            try:
                with open(label_file) as f:
                    label = f.read().strip()
            except OSError:
                continue
            if label in label_map:
                try:
                    with open(inp) as f:
                        result[label_map[label]] = round(int(f.read().strip()) / 1000, 1)
                except (OSError, ValueError):
                    pass
        break
    return result


def read_cpu_temp():
    return _read_hwmon("k10temp", {"Tctl": "cpu_tctl", "Tccd1": "cpu_tccd1"})


def read_dram_temp():
    temps = {}
    idx = 0
    for d in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        try:
            with open(os.path.join(d, "name")) as f:
                if f.read().strip() != "spd5118":
                    continue
        except OSError:
            continue
        inp = os.path.join(d, "temp1_input")
        try:
            with open(inp) as f:
                temps[f"dram_{idx}"] = round(int(f.read().strip()) / 1000, 1)
        except (OSError, ValueError):
            pass
        idx += 1
    return temps


def read_nvme_temp():
    result = {}
    idx = 0
    for d in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        try:
            with open(os.path.join(d, "name")) as f:
                if f.read().strip() != "nvme":
                    continue
        except OSError:
            continue
        inp = os.path.join(d, "temp1_input")
        try:
            with open(inp) as f:
                result[f"nvme_{idx}"] = round(int(f.read().strip()) / 1000, 1)
        except (OSError, ValueError):
            pass
        idx += 1
    return result


def _read_sysfs(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def _read_sysfs_int(path):
    v = _read_sysfs(path)
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def _read_hwmon_temps(hwmon_dir):
    """Read labeled temp sensors from an amdgpu hwmon dir."""
    temps = {}
    for inp in glob.glob(os.path.join(hwmon_dir, "temp*_input")):
        label_file = inp.replace("_input", "_label")
        label = _read_sysfs(label_file)
        val = _read_sysfs_int(inp)
        if label and val is not None:
            temps[label.lower()] = round(val / 1000, 1)
    return temps


def read_gpu():
    """Read GPU data from sysfs (amdgpu hwmon + drm). No rocm-smi needed."""
    # Map BDF -> hwmon dir for amdgpu devices
    hwmon_map = {}
    for d in sorted(glob.glob("/sys/class/hwmon/hwmon*")):
        if _read_sysfs(os.path.join(d, "name")) != "amdgpu":
            continue
        dev = os.path.realpath(os.path.join(d, "device"))
        bdf = os.path.basename(dev)
        hwmon_map[bdf] = d

    # Map BDF -> drm card for VRAM info
    vram_map = {}
    for card_dev in sorted(glob.glob("/sys/class/drm/card*/device")):
        driver = os.path.basename(os.path.realpath(os.path.join(card_dev, "driver")))
        if driver != "amdgpu":
            continue
        bdf = os.path.basename(os.path.realpath(card_dev))
        vram_map[bdf] = card_dev

    result = []
    for idx, bdf in enumerate(sorted(hwmon_map.keys())):
        d = hwmon_map[bdf]
        temps = _read_hwmon_temps(d)

        power_uw = _read_sysfs_int(os.path.join(d, "power1_average"))
        fan_rpm = _read_sysfs_int(os.path.join(d, "fan1_input"))

        vram_total = None
        vram_used = None
        card_dev = vram_map.get(bdf)
        if card_dev:
            vt = _read_sysfs_int(os.path.join(card_dev, "mem_info_vram_total"))
            vu = _read_sysfs_int(os.path.join(card_dev, "mem_info_vram_used"))
            if vt:
                vram_total = round(vt / 1048576)
            if vu:
                vram_used = round(vu / 1048576)

        result.append({
            "id": str(idx),
            "bdf": bdf,
            "junction": temps.get("junction"),
            "memory": temps.get("mem"),
            "edge": temps.get("edge"),
            "power_w": round(power_uw / 1_000_000, 1) if power_uw else None,
            "vram_used_mb": vram_used,
            "vram_total_mb": vram_total,
            "fan_rpm": fan_rpm,
        })
    return result


def read_all():
    data = {"timestamp": time.time()}
    data.update(read_cpu_temp())
    data.update(read_dram_temp())
    data.update(read_nvme_temp())
    data["gpus"] = read_gpu()
    return data


class SensorThread(QThread):
    data_ready = pyqtSignal(dict)

    def __init__(self, interval_ms=2000):
        super().__init__()
        self._interval = interval_ms
        self._running = True

    def run(self):
        while self._running:
            try:
                data = read_all()
                self.data_ready.emit(data)
            except Exception:
                pass
            self.msleep(self._interval)

    def stop(self):
        self._running = False
        self.wait(3000)
