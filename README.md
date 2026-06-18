# server-acceptance — 4×R9700 factory acceptance test

A `git clone`-and-run acceptance suite for a freshly assembled **4× ASRock
Radeon AI PRO R9700** (gfx1201 / RDNA4) server. It confirms the machine was
**assembled correctly**, **burns it in** to prove stability under load, and
emits a machine-readable **PASS/FAIL** report tied to a serial number.

This is an **acceptance tool, not a lab stress tool**: it faces a stream of
*unknown* new machines and must catch the bad one and fail fast. See
`PROJECT_PLAN.md` for the full design rationale.

## Quick start (on a freshly assembled machine)

The target machine needs only **git + ROCm + GPU driver** pre-installed.
`deploy.sh` installs everything else.

```bash
git clone <this-repo> server-acceptance
cd server-acceptance
./deploy.sh                      # install deps, docker, sysctl (sudo)
#   if it added you to the docker group: log out/in (or: newgrp docker)
./deploy.sh --pull               # optional: pull the (large) vLLM image now

# 1. Edit the golden spec to match this machine class:
$EDITOR expected_config.yaml

# 2. Verify environment + assembly (read-only, fast):
./preflight.sh
./inventory.sh

# 3. Full acceptance run (preflight -> inventory -> burn-in -> report):
./run_acceptance.sh --serial SN12345 --duration 30m
```

The result lands in `results/<serial>_<timestamp>/` as `report.txt`,
`report.json`, telemetry CSV, logs, and a `.tar.gz` QA artifact.

## Stages (fail fast, in order)

| Stage | Script | What it does |
|---|---|---|
| 1 | `preflight.sh` | go/no-go gate: kernel ≥6.11, ROCm, docker GPU access, host tools. Each failure prints the **fix**. |
| 2 | `inventory.sh` | enumerate vs `expected_config.yaml`: GPU count, **VRAM per card**, PCIe x16/Gen5, NUMA, DIMM/RAM, NVMe. Captures AER + SMART baselines. |
| 3 | `stress/*` | burn-in to steady state: GPU hotspot, VRAM fill, interconnect, CPU/RAM, SSD, combined (PSU peak). |

Never burns in a machine that failed Stage 1 or 2.

## `run_acceptance.sh` options

```
--serial <S>        required: per-unit serial, stamped into the report
--config <file>     expected_config.yaml (default)
--duration <30m>    burn-in steady-state duration (e.g. 90s, 30m, 1h)
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
to a raw device. Default SSD testing is file-based. All stress processes and
containers are tracked and killed on exit / Ctrl-C / error.

## Notes on the current dev machine (2026-06-18)

`expected_config.yaml` is currently filled from the live dev box, which differs
from the production WRX90 target — re-tune the `# TUNE` lines before shipping:

- **single NUMA node** (prod target is dual-NUMA WRX90)
- **~194 GB RAM**, **1× Crucial P310 1TB** NVMe (also the OS disk → file-based fio)
- GPU `0000:e3:00.0` reports **2 GiB less VRAM** than the other three and is
  correctly **FAILED** by `inventory.sh` — swap it for a good card.
- The 4 cards have **inconsistent VRAM ECC** (one enabled, three disabled);
  inventory flags it — make ECC uniform per your fleet policy.

See `PROJECT_PLAN.md` for the complete specification.
