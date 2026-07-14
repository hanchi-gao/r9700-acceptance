# server-acceptance — 4×R9700 factory acceptance test

A `git clone`-and-run acceptance suite for freshly assembled **4× ASRock
Radeon AI PRO R9700** (gfx1201 / RDNA4) servers. It confirms assembly
correctness, **burns in** all subsystems under simultaneous load, and emits a
machine-readable **PASS/FAIL** report tied to a serial number.

**No ROCm needed.** GPU burn-in uses Vulkan compute (mesa-vulkan-drivers,
Ubuntu default). Works on a fresh Ubuntu 24.04 install with no additional
GPU drivers.

## Quick start

```bash
git clone <this-repo> server-acceptance
cd server-acceptance

# STEP 0 — AMD gfx1201 firmware (fresh OS only; skip if already installed)
#   wget https://repo.radeon.com/amdgpu-install/7.2.3/ubuntu/noble/amdgpu-install_7.2.3.70203-1_all.deb
#   sudo apt install ./amdgpu-install_7.2.3.70203-1_all.deb
#   sudo amdgpu-install --usecase=graphics --no-dkms && sudo reboot

# STEP 1 — install dependencies + build Vulkan GPU burn
./deploy.sh                      # apt install + build vk_burn
#   with LLM test:  ./deploy.sh --with-llm

# STEP 2 — edit the golden spec to match this machine class
$EDITOR expected_config.yaml

# STEP 3 — full acceptance run
sudo ./run_acceptance.sh --serial SN12345 --duration 30m

# Or individual stages:
./preflight.sh                   # Stage 1: environment go/no-go
./inventory.sh                   # Stage 2: hardware vs config
./stress/combined.sh --duration 120  # Stage 3: burn-in (seconds)
```

### GUI monitoring (OCCT-style)

```bash
sudo -E python3 gui/main.py
```

> **`sudo -E` is required** — the Stability Test page mounts the fio NVMe
> target (`/mnt/nvme-test`) during burn-in, which needs root.
> `-E` preserves `DISPLAY` / `XAUTHORITY` / `XDG_RUNTIME_DIR` so the GUI
> can connect to the display; plain `sudo` without `-E` will fail to open
> a window.

Three pages:
- **Stability Test** — Light/Full mode, component selection, start/stop, timer
- **Monitoring** — per-sensor checkbox + individual real-time chart cards
- **AI Model** — LLM inference benchmark (per-card tokens/sec)

> ⏱️ **Use `--duration 30m` minimum for real verdicts.** Short runs starve fio
> and produce false FAILs on healthy drives.

## Stages (fail fast, in order)

| Stage | Script | What it does |
|---|---|---|
| 1 | `preflight.sh` | go/no-go: kernel ≥6.11, amdgpu driver, vk_burn, host tools |
| 2 | `inventory.sh` | enumerate vs `expected_config.yaml`: GPU count, VRAM, PCIe x16/Gen5, DRAM type/uniformity, NVMe. Captures AER + SMART baselines |
| 3 | `stress/combined.sh` | burn-in: all subsystems at once — GPU Vulkan compute (fills VRAM), stress-ng (CPU/RAM), fio (SSD). Validates PSU peak + heat soak |

### GPU burn-in

| Binary | What it does | Dependencies |
|---|---|---|
| `build/vk_burn` (Vulkan compute) | ~300W, fills 90% VRAM, sustained FMA | mesa-vulkan-drivers only |

GPUs are addressed by **PCI BDF**, not index. Physical slot position is
mapped in `expected_config.yaml` — FAIL messages show "從CPU數來第N張".

### Light / Full mode

```bash
# Full (default): 90% VRAM, all CPU cores, fio iodepth=32
sudo ./run_acceptance.sh --serial SN001 --duration 30m

# Light: 50% VRAM, half CPU cores, fio iodepth=8
sudo ./run_acceptance.sh --serial SN001 --duration 30m --burnin gpu,cpu,ssd
```

Or select in GUI Stability Test page.

### LLM inference test (optional)

```bash
./deploy.sh --with-llm           # builds llama.cpp (Vulkan backend)
# Place model: models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf
./stress/llm_bench.sh            # per-card tokens/sec benchmark
```

Also available in GUI AI Model page with model download button.

## Thresholds

All numeric thresholds in `lib/thresholds.sh`. Current values (calibrated
from fleet data across 3 machines):

| Metric | WARN | FAIL |
|--------|------|------|
| GPU Junction | 95°C | 100°C |
| GPU VRAM | 96°C | 100°C |
| CPU Tctl | 85°C | 90°C |
| NVMe | 70°C | 80°C |
| SSD Seq Read | — | 10000 MB/s |
| SSD Seq Write | — | 9000 MB/s |
| Thermal Throttle | — | 0 events |
| AER / MCE / GPU Reset | — | 0 delta |

## `run_acceptance.sh` options

```
--serial <S>        required: per-unit serial
--config <file>     expected_config.yaml (default)
--duration <30m>    burn-in length (e.g. 90s, 30m, 1h)
--mode <full|preflight|inventory|burnin>
--burnin <COMP>     components: gpu,cpu,ssd or "all" (default)
--fio-target <path> SSD test target (default: guarded file in results/)
```

## Configuration

- **`expected_config.yaml`** — golden spec: GPU count, VRAM, PCIe link, DRAM
  type, slot→position mapping, RAM, NVMe
- **`lib/thresholds.sh`** — all PASS/FAIL/WARN thresholds. Tune here only

## Safety

`stress/ssd.sh` has a **mandatory write guard**: refuses to write to any
device hosting a mounted filesystem. Default SSD testing is file-based.
All stress processes are tracked by PID and killed on exit/Ctrl-C/error.

## Dependencies

| Layer | Packages | Required? |
|-------|----------|-----------|
| Base | mesa-vulkan-drivers, libvulkan1 | Ubuntu default |
| Tools | stress-ng, fio, memtester, smartmontools, jq | `./deploy.sh` |
| Build | libvulkan-dev, glslang-tools, g++ | `./deploy.sh` |
| GUI | PyQt6, pyqtgraph | `pip install` |
| LLM | llama.cpp (Vulkan build) | `./deploy.sh --with-llm` |

**No ROCm, no Docker, no network at runtime.**
