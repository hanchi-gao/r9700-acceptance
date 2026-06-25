THRESHOLDS = {
    "gpu_junction": {"warn": 98, "fail": 103, "unit": "°C"},
    "gpu_memory":   {"warn": 100, "fail": 104, "unit": "°C"},
    "cpu_tctl":     {"warn": 85, "fail": 95, "unit": "°C"},
    "cpu_tccd1":    {"warn": 85, "fail": 95, "unit": "°C"},
    "nvme":         {"warn": 75, "fail": 83, "unit": "°C"},
    "dram":         {"warn": None, "fail": None, "unit": "°C"},
    "gpu_power":    {"warn": None, "fail": None, "unit": "W"},
    "gpu_fan":      {"warn": None, "fail": None, "unit": "RPM"},
}

COLORS = [
    "#2ed573", "#ff4757", "#3498db", "#ffa502",
    "#a29bfe", "#ff6b81", "#1abc9c", "#fdcb6e",
    "#e74c3c", "#00cec9", "#6c5ce7", "#fab1a0",
]
