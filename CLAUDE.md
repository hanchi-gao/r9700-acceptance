# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Factory acceptance test suite for 4× ASRock Radeon AI PRO R9700 (gfx1201/RDNA4) servers. It verifies assembly correctness, burns in all subsystems under simultaneous load, and emits a machine-readable PASS/FAIL report tied to a serial number. Self-contained — no docker, no network at runtime; burn-in uses HIP kernels compiled locally with `hipcc` + rocBLAS.

## Running

```bash
# Full acceptance (requires ROCm + driver installed, run deploy.sh first):
sudo ./run_acceptance.sh --serial SN12345 --duration 30m

# Burn only specific subsystems (comma-separated: gpu, cpu, ssd):
sudo ./run_acceptance.sh --serial SN12345 --duration 30m --burnin gpu
sudo ./run_acceptance.sh --serial SN12345 --duration 30m --burnin gpu,cpu

# Individual stages:
./preflight.sh                    # Stage 1: environment go/no-go
./inventory.sh                    # Stage 2: hardware vs expected_config.yaml
./stress/combined.sh --duration 120  # Stage 3: burn-in (seconds, not duration string)

# Standalone stress scripts (useful for targeted testing):
./stress/gpu_vram.sh --duration 120     # GEMM VRAM burn (all GPUs)
./stress/gpu_hotspot.sh --duration 120  # FMA junction burn (standalone, not in default burn-in)
./stress/cpu_mem.sh --duration 120      # stress-ng + memtester
./stress/ssd.sh --duration 120          # fio (write-guarded)

# Setup (fresh machine):
./install_rocm.sh   # ROCm + amdgpu driver, then reboot
./deploy.sh         # host deps + pre-build GPU kernels
```

Use `--duration 30m` minimum for real verdicts — short runs starve fio and produce false FAILs on healthy drives.

## Architecture

**Execution flow:** `run_acceptance.sh` orchestrates three stages in strict order — preflight, inventory, burn-in — aborting immediately if any early stage fails. `monitor.sh` runs as a background telemetry logger during burn-in; `lib/postcheck.sh` judges deltas afterward.

**Shared library:** All scripts source `lib/common.sh` which provides logging, the PASS/FAIL accumulator (`checks.tsv`), YAML config reader (`cfg`/`cfg_list` via python3+PyYAML), GPU BDF enumeration helpers, `build_hip`, `resolve_deadline`, and process cleanup tracking.

**Key design rules:**
- GPUs are always addressed by **PCI BDF**, never by index (HIP index ≠ rocm-smi index on this platform).
- All numeric thresholds live in `lib/thresholds.sh` — no magic numbers in logic scripts.
- The burn-in runs all subsystems simultaneously to one shared deadline (worst-case PSU + thermal).
- `fio` writes are guarded: `stress/ssd.sh` refuses to write to any mounted filesystem or OS disk.
- Root-gated checks (PCIe LnkSta, SMART, AER, dmesg) degrade to WARN, never silently skip.

**Config:** `expected_config.yaml` defines the golden spec per machine class. `--serial` is per-unit at runtime. Lines marked `# TUNE` need adjustment for production hardware (currently set to the dev box).

**Results:** Each run produces `results/<serial>_<timestamp>/` containing `report.json`, `report.txt`, `telemetry.csv`, `events.log`, baseline snapshots, and a `.tar.gz` QA artifact.

## Code layout

- `src/gemm_burn.hip` — rocBLAS GEMM kernel (VRAM fill + memory temp burn, the default burn-in GPU load)
- `src/gpu_burn.hip` — FMA loop kernel (junction/hotspot burn, standalone probe only)
- `lib/report.sh` — generates report.json + report.txt + tarball
- `lib/postcheck.sh` — post-burn-in delta checks (AER, SMART, peak temps, MCE, GPU reset)

## Environment notes

- Requires Ubuntu with kernel ≥ 6.11 (6.8 doesn't enumerate gfx1201).
- ROCm ≥ 7.0 with `hipcc` and `rocBLAS`.
- `mcelog` is absent on Ubuntu 24.04 noble; MCE detection falls back to dmesg scanning.
- `deploy.sh` installs packages one-by-one so one missing package doesn't abort the rest.
