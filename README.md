# server-acceptance — 4×R9700 factory acceptance test

A `git clone`-and-run acceptance suite for a freshly assembled **4× ASRock
Radeon AI PRO R9700** (gfx1201 / RDNA4) server. It confirms the machine was
**assembled correctly**, **burns it in** to prove stability under load, and
emits a machine-readable **PASS/FAIL** report tied to a serial number.

This is an **acceptance tool, not a lab stress tool**: it faces a stream of
*unknown* new machines and must catch the bad one and fail fast. See
`PROJECT_PLAN.md` for the full design rationale.

## Quick start (on a freshly assembled machine)

The target machine needs only **Ubuntu + git**. `install_rocm.sh` installs the
ROCm stack + amdgpu driver; `deploy.sh` installs everything else.

```bash
git clone <this-repo> server-acceptance
cd server-acceptance

# STEP 0 — install ROCm + amdgpu driver, then REBOOT (skip if ROCm already present).
# Follows the official quick-start; defaults to ROCm 7.2.4 for gfx1201 / R9700.
#   https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html
./install_rocm.sh                # adds repo, installs amdgpu-dkms + rocm, prompts reboot
#   override version if needed:  ROCM_VERSION=7.2.4 ./install_rocm.sh
#   ... reboot, then verify:     rocm-smi

# STEP 1 — install the rest of the suite's dependencies (sudo for apt).
./deploy.sh                      # host tools + pre-builds the GPU burn kernels
#   No docker needed: burn-in uses self-contained HIP kernels.

# STEP 2 — edit the golden spec to match this machine class:
$EDITOR expected_config.yaml

# STEP 3 — verify environment + assembly (read-only, fast):
./preflight.sh
./inventory.sh

# STEP 4 — full acceptance run (preflight -> inventory -> burn-in -> report):
./run_acceptance.sh --serial SN12345 --duration 30m
```

The result lands in `results/<serial>_<timestamp>/` as `report.txt`,
`report.json`, telemetry CSV, logs, and a `.tar.gz` QA artifact.

## Stages (fail fast, in order)

| Stage | Script | What it does |
|---|---|---|
| 1 | `preflight.sh` | go/no-go gate: kernel ≥6.11, ROCm, hipcc + rocBLAS, host tools. Each failure prints the **fix**. |
| 2 | `inventory.sh` | enumerate vs `expected_config.yaml`: GPU count, **VRAM per card**, PCIe x16/Gen5, NUMA, DIMM/RAM, NVMe. Captures AER + SMART baselines. |
| 3 | `stress/combined.sh` | burn-in: **all subsystems at once** for `--duration` — GPU GEMM (fills VRAM), stress-ng (CPU/RAM), fio (SSD). Validates PSU peak + heat soak while VRAM is occupied. |

The orchestrator runs **one combined stage** (everything simultaneously). The
monitor logs temps/power/events throughout; `postcheck.sh` then judges peak
temps, AER/MCE/reset, and SMART deltas.

### GPU burn-in loads (self-contained — no docker / vLLM / network)

| Kernel | Effect on each R9700 (measured) | Used by |
|---|---|---|
| `src/gemm_burn.hip` (rocBLAS GEMM, fill 90%) | ~300 W, **fills ~29.5 GB VRAM**, **memory ~86 °C** | combined burn-in (`gpu_vram.sh`) |
| `src/gpu_burn.hip` (FMA loop) | ~300 W, **junction ~95 °C**, ~512 MB VRAM | standalone max-junction probe (`gpu_hotspot.sh`) |

Both compile at runtime with `hipcc` (GEMM also links rocBLAS, which ships with
ROCm). GPUs are addressed/attributed by **PCI BDF**, not index — HIP device order
does not match rocm-smi order on this platform. The individual `stress/*.sh`
scripts remain runnable standalone for targeted testing.

Never burns in a machine that failed Stage 1 or 2.

## Run as root for full coverage

Several real checks need root and degrade to **WARN** (never silently skipped)
when run as a normal user. For a complete factory acceptance, run with `sudo`:

```bash
sudo ./run_acceptance.sh --serial <SN> --duration 30m
```

Root-gated checks: **PCIe link width/speed** (`lspci -vvv` LnkSta — catches a
card that negotiated down to x8/Gen3, invisible to GPU tools), **NVMe SMART**
baseline/delta, **PCIe AER** baseline/delta, and the **dmesg** scan for MCE /
GPU-reset events. Without root these report WARN; the verdict can still be
ACCEPTED but the assembly/error coverage is incomplete.

## Known limitations / notes

- **VRAM ECC**: `inventory.sh` checks all 4 cards share the same VRAM ECC (UMC)
  mode. If `rocm-smi --showrasinfo` reports no UMC block (RAS reporting off), the
  check WARNs (cannot verify) — enable ECC/RAS in BIOS to verify it, and set
  `gpu.vram_ecc_enabled` to your fleet policy.
- **Interconnect (rccl) is not implemented.** Inter-GPU P2P is fully supported on
  this platform (full mesh), but rccl-tests is not bundled (no network at build
  time) and is left as future work — the burn-in does not test interconnect.
- **Memory temperature runs warm** (~96–97 °C peak even in a 2-min run; FAIL at
  99 °C). Watch it on a full 30-min steady-state run.

## `run_acceptance.sh` options

```
--serial <S>        required: per-unit serial, stamped into the report
--config <file>     expected_config.yaml (default)
--duration <30m>    burn-in length (e.g. 90s, 30m, 1h). One combined stage runs
                    all subsystems at once for this long.
--mode <full|preflight|inventory|burnin>
--fio-target <path> SSD test target (default: a guarded file in results/)
```

## Configuration

- **`expected_config.yaml`** — the golden spec this machine class must match
  (GPU count, VRAM floor, PCIe link, NUMA topology, RAM, NVMe). Edit per class.
- **`lib/thresholds.sh`** — all numeric PASS/FAIL/WARN thresholds (temps, fio
  floors, error-count deltas). Tune here only; no magic numbers in logic.

## Safety

`stress/ssd.sh` has a **mandatory write guard** (plan §8): it refuses to write
to any device hosting a mounted filesystem (especially `/`) and never defaults
to a raw device. Default SSD testing is file-based. All stress processes are
tracked by PID and killed on exit / Ctrl-C / error.

## Notes on the current dev machine (2026-06-18)

`expected_config.yaml` is currently filled from the live dev box, which differs
from the production WRX90 target — re-tune the `# TUNE` lines before shipping:

- **single NUMA node** (prod target is dual-NUMA WRX90)
- **~194 GB RAM**, **1× Crucial P310 1TB** NVMe (also the OS disk → file-based fio)
- All 4 cards now report a uniform **31.86 GiB VRAM** and pass inventory. (A card
  at `0000:e3:00.0` previously read 2 GiB short and was correctly **FAILED** by
  `inventory.sh` until repaired — the VRAM floor + cross-card spread check catch
  a short/odd card.)
- `inventory.sh` also checks **VRAM ECC consistency** across the 4 cards; set the
  intended mode via `vram_ecc_enabled` and make BIOS/rocm-smi uniform.

See `PROJECT_PLAN.md` for the complete specification.
