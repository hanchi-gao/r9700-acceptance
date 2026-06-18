# PROJECT_PLAN.md — `server-acceptance`

> 4×R9700 newly-assembled server **acceptance test** suite.
> This document is the spec for Claude Code to develop the project on a live 4-card test machine.
> Read the whole file before writing any code. Develop **incrementally**, one stage at a time, and verify on real hardware between stages.

---

## 1. Goal & Non-Goals

**Goal:** A `git clone`-and-run tool that an operator uses on a freshly assembled 4×R9700 server to:
1. Confirm the machine was **assembled correctly** (hardware enumeration, PCIe link, NUMA mapping, VRAM size).
2. **Burn it in** to confirm stability under sustained load (GPU compute, VRAM, interconnect, CPU, RAM, SSD).
3. Emit a **machine-readable PASS/FAIL report** tied to a serial number, as a shippable QA record.

**This is an acceptance tool, not a lab stress tool.** The difference matters and drives every design decision:
- A lab stress tool pushes *known-good* hardware to its limit.
- An acceptance tool faces a stream of *unknown* new machines and must **catch the bad one** and **fail fast**.

**Non-Goals:**
- No cold-boot / re-enumeration test (explicitly out of scope for this project).
- Not a benchmarking/performance-tuning tool (we check against floors/thresholds, not chase peak numbers).
- Does not modify firmware or flash anything.

---

## 2. Core Design Principles (do not violate)

1. **Fail fast, in order.** `preflight → inventory → (abort if either fails) → burn-in`. Never burn-in a machine that failed assembly checks. A mis-assembled machine must report *which* check failed in seconds, not after 30 minutes.

2. **No hardcoded skips. Ever.** The whole point of acceptance is to *catch* a bad card. Do **not** hardcode skipping any GPU index. (Historically GPU index 1 / BDF `0000:06:00.0` on the dev machine reported 8GB due to an HBM fault — **that card is now repaired**, so the dev machine is currently a healthy "golden sample". Use it to verify the tool produces **all-PASS with zero false positives** on good hardware. The tool itself must remain skip-free so it catches the *next* bad card on a different machine.)

3. **Compare against an expected config, don't assume.** All "correctness" checks compare *actual* hardware against `expected_config.yaml`. Count, VRAM size, PCIe width/speed, BDF↔NUMA mapping, DIMM/NVMe counts all come from the expected file. Mismatch → FAIL with the offending detail.

4. **Automated PASS/FAIL, no human eyeballing.** Every criterion is a programmatic threshold. The operator reads `PASS` or `FAIL` + a reason list, not a graph.

5. **Destructive operations must be guarded.** Especially `fio` writes — see §8 Safety.

---

## 3. Hardware / Software Target

- **GPUs:** 4× ASRock Radeon AI PRO R9700 (gfx1201 / RDNA4), 32GB each, PCI ID `[1002:7551]`.
- **Platform:** WRX90 / WS EVO class board, dual NUMA. Example topology — Node 0: `03:00.0`, `06:00.0`; Node 1: `e3:00.0`, `e6:00.0` (actual mapping lives in `expected_config.yaml`).
- **OS:** Ubuntu 24.04, **kernel ≥ 6.11** (required — kernel 6.8 does **not** recognize PCI ID `[1002:7551]`; gfx1201 won't enumerate. `linux-generic-hwe-24.04` is acceptable).
- **ROCm:** 7.x (matches host install; preflight validates version).
- **Container (for VRAM stage):** `asrock_henrygao/rocm-vllm:rocm7.1_ubuntu22.04_py3.12_pytorch_release_2.9.0_vllm0.13.0`.
- **host sysctl for vLLM:** `kernel.numa_balancing=0` (cross-NUMA KV faults otherwise).

---

## 4. Repository Structure

```
server-acceptance/
├── README.md
├── deploy.sh                # one-shot after git clone: install deps, sanity-check env
├── expected_config.yaml     # the golden spec this machine class must match
├── preflight.sh             # Stage 1: go/no-go gate
├── inventory.sh             # Stage 2: hardware enumeration + compare vs expected
├── run_acceptance.sh        # orchestrator → PASS/FAIL report
├── monitor.sh               # background telemetry logger (CSV)
├── lib/
│   ├── common.sh            # shared: logging, color, PASS/FAIL accumulator, yaml read
│   └── thresholds.sh        # all numeric thresholds in one place
├── stress/
│   ├── gpu_hotspot.sh       # gpu_burn per-GPU parallel (junction temp)
│   ├── gpu_vram.sh          # vLLM VRAM fill + memory temp (one container per GPU)
│   ├── gpu_interconnect.sh  # rccl-tests all-reduce under thermal load
│   ├── cpu_mem.sh           # stress-ng + memtester, both NUMA nodes
│   ├── ssd.sh               # fio read/write WITH write-safety guard
│   └── combined.sh          # GPU+CPU+SSD simultaneously → PSU peak / worst-case heat
├── src/
│   └── gpu_burn.hip         # compute stress (FMA loop), fallback if ROCm/gpu-burn clone fails
├── vram_stress.py           # vLLM offline-inference VRAM stress (runs inside container)
└── results/
    └── <serial>_<timestamp>/   # created at runtime: CSVs, logs, report.json, report.txt, tarball
```

---

## 5. `expected_config.yaml` (schema)

Operator fills this per machine class. Inventory compares against it.

```yaml
machine_class: "ASRock-4xR9700-WRX90"
gpu:
  count: 4
  pci_id: "1002:7551"
  vram_gb_each: 32
  pcie_link_width: 16        # x16
  pcie_link_speed: "32GT/s"  # Gen5
  # BDF -> expected NUMA node
  topology:
    - bdf: "0000:03:00.0"
      numa_node: 0
    - bdf: "0000:06:00.0"
      numa_node: 0
    - bdf: "0000:e3:00.0"
      numa_node: 1
    - bdf: "0000:e6:00.0"
      numa_node: 1
cpu:
  numa_nodes: 2
memory:
  dimm_count: 8
  total_gb_min: 256
storage:
  nvme_count: 1
kernel:
  min_version: "6.11"
rocm:
  min_version: "7.0"
```

> Note: `serial` is **not** in this file. It's passed at runtime (`--serial`) since it's per-unit, not per-class.

---

## 6. Stage Details

### Stage 1 — `preflight.sh` (go/no-go gate)
Block known environment problems that would make burn-in a waste of time. Each check prints the problem **and the fix**, then exits non-zero on failure.

- [ ] Kernel ≥ `expected.kernel.min_version`. If lower → FAIL "kernel X < 6.11; gfx1201 PCI ID 1002:7551 won't enumerate; install linux-generic-hwe-24.04".
- [ ] ROCm installed and ≥ `expected.rocm.min_version` (`cat /opt/rocm/.info/version` or `rocminfo`).
- [ ] `rocm-smi` runs and returns without error.
- [ ] Docker present, daemon reachable **without sudo** (`docker info`). If permission denied → FAIL with `usermod -aG docker $USER` hint.
- [ ] Docker can access GPUs: launch the vLLM image with `/dev/kfd` + `/dev/dri`, resolved render/video GIDs, run `rocm-smi` inside. Must list GPUs.
  - **GID resolution (critical):** container group GIDs may not match host. Resolve at runtime:
    `RENDER_GID=$(getent group render | cut -d: -f3)`, `VIDEO_GID=$(getent group video | cut -d: -f3)`, pass `--group-add $RENDER_GID --group-add $VIDEO_GID`.
- [ ] Required host tools present: `lspci`, `fio`, `stress-ng`, `memtester`, `smartctl`/`nvme`, `sensors`, `ipmitool` (warn-only if no IPMI), `mcelog` or dmesg-MCE fallback. `deploy.sh` installs these.

### Stage 2 — `inventory.sh` (enumerate + compare)
Compare actual hardware to `expected_config.yaml`. Any mismatch → FAIL with the specific item + BDF.

- [ ] **GPU count** == expected. (`rocm-smi` / `lspci -d 1002:7551`)
- [ ] **VRAM per GPU** == 32GB for every card. **This is the check that catches "the next GPU1".** Any card reporting < 32GB → FAIL with its BDF.
- [ ] **PCIe link width/speed per card** — the most common 4-card assembly fault (bad seating/riser negotiates down to x8 or Gen3; card still works but half-bandwidth). Per card:
  `lspci -d 1002:7551 -vvv | grep -E 'LnkCap|LnkSta'` — compare **LnkSta** (negotiated) to expected x16 Gen5. Downgraded → FAIL + BDF.
- [ ] **PCIe AER baseline** — record `cat /sys/bus/pci/devices/<bdf>/aer_dev_correctable` per card *before* burn-in. Store as baseline; compared again post-burn-in (§7).
- [ ] **BDF ↔ NUMA mapping** matches expected topology (`cat /sys/bus/pci/devices/<bdf>/numa_node`).
- [ ] **DIMM count / total RAM** ≥ expected (`dmidecode -t memory` or `lsmem`).
- [ ] **NVMe count** == expected (`nvme list` / `lsblk`).
- [ ] **NVMe SMART baseline** — capture per drive before burn-in (reallocated, media errors, wear, temp) for post-burn-in delta.

### Stage 3 — Burn-in (`stress/*`)
Run to **steady state (30–60 min)**, all subsystems loaded. Record inlet ambient as the temperature baseline.

- **`gpu_hotspot.sh`** — max junction temp. Try `git clone https://github.com/ROCm/gpu-burn` + build with `hipcc`; on clone/build failure, fall back to compiling `src/gpu_burn.hip`. Auto-detect arch via `rocminfo` for `--offload-arch` (expect `gfx1201`). Launch one process **per GPU in parallel**, each pinned with `HIP_VISIBLE_DEVICES=<id>` (independent instances — no TP, no sync bubbles → continuous compute → max junction).
- **`gpu_vram.sh`** — fill VRAM + drive memory temp. One container **per GPU**, each `-e HIP_VISIBLE_DEVICES=<id>`, devices + resolved GIDs, running `vram_stress.py`. All GPUs parallel; `docker stop` after duration. Every card must fill ~32GB now that GPU1 is repaired.
- **`vram_stress.py`** — vLLM offline inference. Args: `--model` (default `Qwen2.5-14B-Instruct`), `--gpu-mem-util 0.95`, `--max-model-len 8192`, `--duration`, `--concurrency 64`. Load with `dtype=bfloat16`, `enable_prefix_caching=False` (cross-NUMA KV faults), `max_model_len`. Build `concurrency` long prompts near `max_model_len`, loop `llm.generate()` with `SamplingParams(ignore_eos=True, max_tokens=large)` until duration → KV cache stays full → sustained memory bandwidth. Print reserved/total VRAM + tok/s; catch & report HIP/OOM; **non-zero exit on any error**.
- **`gpu_interconnect.sh`** — `rccl-tests` all-reduce sustained, to verify interconnect stability **under thermal load** (lab baseline ~40 GB/s bus BW, ~57 GB/s P2P — but acceptance cares about *no degradation / no PCIe errors under heat*, not the absolute number). Watch for bandwidth collapse and PCIe errors during the run.
- **`cpu_mem.sh`** — `stress-ng` (all cores) + `memtester` / `stress-ng --vm`. **Both NUMA nodes / all channels** (GPU stress can't touch most system RAM; bad DIMMs only surface here).
- **`ssd.sh`** — `fio` random+sequential R/W. **See §8 — write guard is mandatory.**
- **`combined.sh`** — GPU + CPU + SSD simultaneously. Purpose is **PSU peak validation** (4 cards + CPU full draw is the worst case; weak PSU shows as a transient reset or a card dropping power), plus worst-case chassis heat soak.

---

## 7. `monitor.sh` (background telemetry)
Poll every 2s during all burn-in stages. Append to `results/<serial>_<ts>/telemetry.csv`.

**CSV columns:**
`timestamp, gpu_id, bdf, junction_temp, memory_temp, edge_temp, power_draw_w, vram_used_mb, vram_total_mb, gpu_clock_mhz, mem_clock_mhz, throttle_status, ecc_total, nvme_temp, fan_rpm, chassis_power_w`

Plus a separate **event log** (`events.log`) scanning continuously:
- `dmesg` for `AER`, `Machine check`, GPU reset (`amdgpu` ring/reset messages).
- Throttle detection: flag when `gpu_clock_mhz` drops while at thermal limit.
- MCE via `mcelog` if available, else dmesg `Machine check` grep.

Post-burn-in, re-capture and **delta** against Stage-2 baselines: AER counters, NVMe SMART (reallocated/media/wear). Any increment → FAIL.

---

## 8. Safety (mandatory guards)

**fio write guard — this can destroy a customer's OS disk if wrong.**
- `ssd.sh` must **refuse** to write to any device that hosts a mounted filesystem (especially `/`).
- Resolve the root device (`findmnt -no SOURCE /` → parent disk) and **reject** if the fio target matches it.
- Default to file-based testing on a mounted data filesystem (`--filename=/data/fio_test.tmp`, cleaned up after) OR an explicitly named **unmounted raw device**. Never default to a raw device path.
- Print the resolved target and require it to pass the guard before any write op.

**General:** stress processes must be tracked by PID and reliably killed/`docker stop`-ed on duration end, Ctrl-C, or error (trap EXIT). No orphaned gpu_burn or containers.

---

## 9. PASS/FAIL Criteria (all automated)

| Check | PASS condition |
|---|---|
| GPU count | == expected (4) |
| VRAM per card | == 32GB on every card |
| PCIe link (per card) | negotiated x16 Gen5 (LnkSta) |
| BDF↔NUMA | matches expected topology |
| DIMM / RAM | count & total ≥ expected |
| NVMe count | == expected |
| Junction temp | < threshold (thresholds.sh) for all cards |
| Memory temp | < threshold |
| Throttling | no clock drop at thermal limit |
| AER delta | 0 new correctable/uncorrectable post-burn-in |
| MCE | none during burn-in |
| GPU reset | none in dmesg |
| fio bandwidth | > floor (thresholds.sh) |
| NVMe SMART delta | no new reallocated/media errors |
| Fan response | RPM rises under load (no fan stuck at 0) |
| Interconnect | no bandwidth collapse / PCIe errors under load |

Thresholds centralized in `lib/thresholds.sh` so they're tunable without touching logic.

---

## 10. `run_acceptance.sh` (orchestrator)

**Args:** `--serial <S>` (required), `--config expected_config.yaml`, `--duration 30m`, `--mode {full|preflight|inventory|burnin}`, `--gpus all`, `--fio-target <path>`.

**Flow:**
1. Create `results/<serial>_<timestamp>/`.
2. `preflight.sh` → on fail, write report, **abort**.
3. `inventory.sh` (capture baselines) → on fail, write report, **abort**.
4. Start `monitor.sh` in background.
5. Burn-in: hotspot → vram → interconnect → cpu_mem → ssd → combined (or per mode). All GPU-parallel stages run their cards simultaneously.
6. Stop monitor; capture post-burn-in deltas (AER, SMART).
7. Generate `report.json` (machine-readable) + `report.txt` (operator-readable): per-check PASS/FAIL, peak junction/memory temps, avg/peak power, throttle events, AER/MCE/reset counts, VRAM error count, fio BW, top-line **ACCEPTED / REJECTED**.
8. Tarball the whole results dir as the QA artifact.

---

## 11. Development Workflow for Claude Code (on the live test machine)

Develop **incrementally** and verify on real hardware at each step — do not write all scripts then run once.

1. **Scaffold first:** repo structure, `lib/common.sh` (logging + PASS/FAIL accumulator + yaml reader), `expected_config.yaml` filled in from this machine's actual topology, `lib/thresholds.sh` with sane starting values.
2. **`preflight.sh`** → run it. This machine should pass every gate (kernel ≥6.11, ROCm ok, docker GPU access ok). Fix any gate that wrongly fails on known-good hardware.
3. **`inventory.sh`** → run it. On this (golden) machine it must report **4×32GB, all x16 Gen5, correct NUMA** and **PASS**. This proves no false positives. Temporarily hand-edit `expected_config.yaml` (e.g. set vram to 99GB) to confirm it correctly produces a FAIL, then revert — proves the comparison logic works.
4. **`monitor.sh`** standalone → confirm CSV columns populate with real values (junction, memory temp, ECC, nvme temp, fan rpm). Some fields may be unsupported on this platform — detect and write `N/A` rather than crashing.
5. **Each stress script individually, short duration (e.g. 2m)** before wiring into the orchestrator:
   - `gpu_hotspot.sh` → junction temps climb on all 4.
   - `gpu_vram.sh` → all 4 fill ~32GB, memory temps climb.
   - `ssd.sh` → **test the write guard first**: point it at `/` and confirm it refuses. Only then run a real file-based test.
   - `cpu_mem.sh`, `gpu_interconnect.sh`, `combined.sh`.
6. **`run_acceptance.sh --mode full --duration 5m`** end-to-end smoke test → produces a complete report + tarball.
7. Only then a real **30m** run for the steady-state/heat-soak validation.

**Guardrails while developing:**
- Never run destructive fio against a mounted disk, even in testing.
- Always clean up stress processes/containers between iterations (`docker ps`, `pkill gpu_burn`) so a crashed dev run doesn't leave a card pinned.
- Keep all tunables in `lib/thresholds.sh` and `expected_config.yaml`; no magic numbers in logic.

---

## 12. Known Environment Gotchas (encode these, don't rediscover them)

- **Kernel 6.8 won't enumerate gfx1201** (`[1002:7551]`). Require ≥6.11. Preflight must catch this explicitly.
- **Docker GPU access needs runtime-resolved render/video GIDs** — container group names don't reliably map to host device-owning GIDs. Always resolve numeric GID and `--group-add` it. Also pass `--device=/dev/kfd --device=/dev/dri --security-opt seccomp=unconfined`.
- **vLLM:** `enable_prefix_caching=False` is required (cross-NUMA KV block faults), set host `kernel.numa_balancing=0`.
- **fio is a footgun** — see §8. This is the one mistake that ruins a customer machine.
- **PCIe down-negotiation is invisible to GPU tools** — a card at x8/Gen3 passes every functional GPU test while delivering half bandwidth. Only `lspci LnkSta` catches it. Don't skip it.
- **System RAM is invisible to GPU stress** — needs its own `memtester`/`stress-ng --vm` across both NUMA nodes.
