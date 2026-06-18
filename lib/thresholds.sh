#!/usr/bin/env bash
# lib/thresholds.sh
# Central place for all acceptance PASS/FAIL/WARN thresholds.
# No magic numbers anywhere else in the suite — tune here only.

# =============================================================
# GPU JUNCTION (hotspot) TEMPERATURE  [°C]
# -------------------------------------------------------------
# Hardware throttle/limit for R9700 is ~110°C. We FAIL well below
# that so a card that merely "didn't burn out" is NOT auto-passed.
#
# Anchor: golden reference machine peaked at 102°C under FMA
# (gpu_burn, worst-case compute) in lab ambient on 2026-06-17.
# FAIL = 103 = golden peak + 1°C  ("hotter than our known-good ref → reject")
#
# IMPORTANT: 103 assumes acceptance is run at the SAME inlet ambient
# as the golden baseline. monitor.sh logs inlet ambient every run;
# if a run's ambient is materially higher than the baseline, this
# threshold must be re-evaluated for that run (see report.txt).
# =============================================================
GPU_JUNCTION_WARN_C=98     # early signal: hotter than golden ref, investigate cooling
GPU_JUNCTION_FAIL_C=103    # golden FMA peak (102) + 1°C; hard limit ~110 leaves margin

# Inlet ambient the FAIL line is anchored to. Record actual ambient
# of the golden run here; used by report to flag ambient drift.
GPU_JUNCTION_BASELINE_AMBIENT_C=28   # golden FMA-peak (102°C) run was at ~28°C inlet

# =============================================================
# GPU MEMORY (GDDR6) TEMPERATURE  [°C]
# -------------------------------------------------------------
# Anchor (RECALIBRATED 2026-06-18): golden machine plateaued at 100°C under a
# 30-min GEMM VRAM burn (stress/gpu_vram.sh) with ZERO errors — AER/MCE/SMART
# all clean, junction only 93°C, temp stable (not runaway). It held there the
# whole run.
# The previous 98/99 anchor was set against the OLD vLLM VRAM fill, which heats
# GDDR6 less than the current GEMM burn; against GEMM it produced a false REJECT
# on a known-good machine (golden must be all-PASS, zero false positives).
#   WARN = 100 = golden GEMM steady-state peak — investigate anything above it.
#   FAIL = 104 = golden + 4°C margin, kept below the ~105°C GDDR6 operating
#          limit (confirm against the R9700 GDDR6 datasheet before tightening).
# Ambient still matters: a materially warmer inlet than the golden run pushes
# memory temp up — re-anchor per site if inlet differs from the golden baseline.
# =============================================================
GPU_MEMORY_WARN_C=100
GPU_MEMORY_FAIL_C=104

# =============================================================
# THERMAL THROTTLING
# Any clock drop while at thermal limit during steady state = FAIL.
# =============================================================
THROTTLE_ALLOWED=0         # 0 = no throttle events tolerated

# =============================================================
# SSD / NVMe
# -------------------------------------------------------------
# DEV BOX (2026-06-18): Crucial P310 1TB (CT1000P310SSD2) — PCIe Gen4 x4,
# ~7,100 MB/s read / ~6,000 MB/s write datasheet. It is ALSO the OS disk,
# so ssd.sh is file-based + write-guarded (see stress/ssd.sh, plan §8).
#
# GOLDEN/PROD (TUNE): Crucial T710 2TB — PCIe Gen5 x4, ~14,500/13,800 MB/s.
#
# The fio floor is only a COARSE BACKSTOP for "fell back to a slower link" /
# "dead drive", NOT a perf grade — fio absolute MB/s depends heavily on block
# size / QD / numjobs and on file-vs-raw. The PRIMARY "installed correctly"
# signals are the PCIe link-speed check in inventory.sh and the
# "throughput stable over a sustained run" throttle check below.
#
# To use as a real perf gate: run fio on the golden machine with the FINAL
# fio config, then set floor = ~85% of the observed result.
# =============================================================
SSD_SEQ_READ_FLOOR_MBPS=4000     # Gen4-era backstop; raise to ~9000 for Gen5 golden
SSD_SEQ_WRITE_FLOOR_MBPS=3000    # Gen4-era backstop; raise to ~8000 for Gen5 golden

# NVMe temperature [°C] — PROVISIONAL, recalibrate to observed steady-state.
# T710 runs cooler than T700/T705 but Gen5 + GPU-exhaust airflow can still
# throttle. The real throttle signal is throughput dropping while temp rises;
# treat absolute temp as secondary. Confirm throttle point from SMART/datasheet.
SSD_NVME_TEMP_WARN_C=75
SSD_NVME_TEMP_FAIL_C=83
# Throughput-drop throttle detector: FAIL if sustained-run MB/s drops more
# than this % below the run's own early-window average (catches thermal fold).
SSD_THROUGHPUT_DROP_FAIL_PCT=15

# =============================================================
# Error-count deltas (post-burn-in minus baseline). Any increment = FAIL.
# =============================================================
AER_CORRECTABLE_DELTA_MAX=0
AER_UNCORRECTABLE_DELTA_MAX=0
MCE_COUNT_MAX=0
GPU_RESET_COUNT_MAX=0
NVME_REALLOCATED_DELTA_MAX=0
NVME_MEDIA_ERROR_DELTA_MAX=0
VRAM_ERROR_MAX=0

export GPU_JUNCTION_WARN_C GPU_JUNCTION_FAIL_C GPU_JUNCTION_BASELINE_AMBIENT_C \
       GPU_MEMORY_WARN_C GPU_MEMORY_FAIL_C THROTTLE_ALLOWED \
       SSD_SEQ_READ_FLOOR_MBPS SSD_SEQ_WRITE_FLOOR_MBPS \
       SSD_NVME_TEMP_WARN_C SSD_NVME_TEMP_FAIL_C SSD_THROUGHPUT_DROP_FAIL_PCT \
       AER_CORRECTABLE_DELTA_MAX AER_UNCORRECTABLE_DELTA_MAX MCE_COUNT_MAX \
       GPU_RESET_COUNT_MAX NVME_REALLOCATED_DELTA_MAX NVME_MEDIA_ERROR_DELTA_MAX \
       VRAM_ERROR_MAX
