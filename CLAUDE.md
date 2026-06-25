# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Factory acceptance test suite for 4× ASRock Radeon AI PRO R9700 (gfx1201/RDNA4) servers. It verifies assembly correctness, burns in all subsystems under simultaneous load, and emits a machine-readable PASS/FAIL report tied to a serial number. Self-contained — no docker, no ROCm, no network at runtime; GPU burn-in uses Vulkan compute compiled locally with `g++` + `libvulkan`.

## Running

```bash
# Setup (fresh Ubuntu 24.04 machine):
./deploy.sh                       # host deps + build Vulkan GPU burn
./deploy.sh --with-llm            # also build llama.cpp for LLM test

# Full acceptance:
sudo ./run_acceptance.sh --serial SN12345 --duration 30m

# Selective burn-in (comma-separated: gpu, cpu, ssd):
sudo ./run_acceptance.sh --serial SN12345 --duration 30m --burnin gpu
sudo ./run_acceptance.sh --serial SN12345 --duration 30m --burnin gpu,cpu

# Individual stages:
./preflight.sh                    # Stage 1: environment go/no-go
./inventory.sh                    # Stage 2: hardware vs expected_config.yaml
./stress/combined.sh --duration 120  # Stage 3: burn-in (seconds)

# Standalone stress scripts:
./stress/gpu_vram.sh --duration 120     # Vulkan VRAM burn (all GPUs)
./stress/gpu_hotspot.sh --duration 120  # FMA junction burn (needs ROCm)
./stress/cpu_mem.sh --duration 120      # stress-ng + memtester
./stress/ssd.sh --duration 120          # fio (write-guarded)
./stress/llm_bench.sh                   # LLM inference benchmark (needs llama-cli)

# GUI monitoring (OCCT-style):
python3 gui/main.py
```

Use `--duration 30m` minimum for real verdicts — short runs starve fio and produce false FAILs on healthy drives.

## Architecture

**Execution flow:** `run_acceptance.sh` orchestrates three stages in strict order — preflight, inventory, burn-in — aborting immediately if any early stage fails. `monitor.sh` runs as a background telemetry logger during burn-in; `lib/postcheck.sh` judges deltas afterward.

**Shared library:** All scripts source `lib/common.sh` which provides logging, the PASS/FAIL accumulator (`checks.tsv`), YAML config reader (`cfg`/`cfg_list` via python3+PyYAML), GPU BDF enumeration helpers, `bdf_to_slot`, `resolve_deadline`, and process cleanup tracking.

**Key design rules:**
- GPUs are always addressed by **PCI BDF**, never by index.
- All numeric thresholds live in `lib/thresholds.sh` — no magic numbers in logic scripts.
- The burn-in runs all subsystems simultaneously to one shared deadline (worst-case PSU + thermal).
- `fio` writes are guarded: `stress/ssd.sh` refuses to write to any mounted filesystem or OS disk.
- Root-gated checks (PCIe LnkSta, SMART, AER, dmesg) degrade to WARN, never silently skip.
- All GPU/CPU/NVMe/DRAM temps read from **sysfs hwmon** — no rocm-smi dependency.

**Config:** `expected_config.yaml` defines the golden spec per machine class, including physical slot positions. `--serial` is per-unit at runtime.

**Results:** Each run produces `results/<serial>_<timestamp>/` containing `report.json`, `report.txt`, `telemetry.csv`, `events.log`, baseline snapshots, and a `.tar.gz` QA artifact.

## Code layout

- `src/vk_burn.cpp` — Vulkan compute GPU burn (VRAM fill + FMA, the default GPU load)
- `src/vk_burn.comp` — GLSL compute shader for vk_burn
- `src/gemm_burn.hip` — legacy rocBLAS GEMM kernel (optional, needs ROCm)
- `src/gpu_burn.hip` — legacy FMA loop kernel (optional, needs ROCm)
- `gui/` — PyQt6 + pyqtgraph desktop GUI (OCCT-style)
- `gui/sensors.py` — unified sensor reader (sysfs hwmon, no rocm-smi)
- `gui/pages/stress_page.py` — stability test page (Light/Full mode)
- `gui/pages/monitor_page.py` — monitoring page (per-sensor chart cards)
- `gui/pages/llm_page.py` — LLM inference test page
- `stress/llm_bench.sh` — per-card LLM inference benchmark
- `lib/report.sh` — generates report.json + report.txt + tarball
- `lib/postcheck.sh` — post-burn-in delta checks (AER, SMART, peak temps, MCE, GPU reset)

## Environment notes

- Requires Ubuntu 24.04+ with kernel ≥ 6.11 (6.8 doesn't enumerate gfx1201).
- GPU burn needs only mesa-vulkan-drivers (Ubuntu default) — no ROCm.
- LLM test optionally uses llama.cpp with Vulkan backend.
- `mcelog` is absent on Ubuntu 24.04 noble; MCE detection falls back to dmesg scanning.
- `deploy.sh` installs packages one-by-one so one missing package doesn't abort the rest.
