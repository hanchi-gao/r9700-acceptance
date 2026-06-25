#!/usr/bin/env bash
# stress/llm_bench.sh — per-card LLM inference benchmark using llama.cpp (HIP).
# Requires ROCm + build/llama-cli + a .gguf model in models/.
#
# Usage: ./stress/llm_bench.sh [--model PATH] [--gpu INDEX|all]
#   --model   path to .gguf file (default: first file in models/)
#   --gpu     GPU index to test, or "all" for sequential per-card (default: all)
#
# Records tokens/sec per card. PASS if inference completes and speed > threshold.

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

LLAMA="$REPO_ROOT/build/llama-cli"
MODEL=""
GPU_SEL="all"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    --gpu)   GPU_SEL="$2"; shift 2;;
    *) shift;;
  esac
done

# --- Preflight ---
if [[ ! -x "$LLAMA" ]]; then
  fail "llm_bench" "llama-cli not found at $LLAMA — run: ./deploy.sh --with-llm"
  exit 1
fi

# Find model
if [[ -z "$MODEL" ]]; then
  MODEL="$(ls "$REPO_ROOT/models/"*.gguf 2>/dev/null | head -1)"
fi
if [[ -z "$MODEL" || ! -f "$MODEL" ]]; then
  fail "llm_bench" "no .gguf model found — place model in models/"
  exit 1
fi
MODEL_NAME="$(basename "$MODEL")"

# Find GPUs with enough VRAM (>=8GB) for LLM. Map to HIP device index.
MIN_VRAM_BYTES=8589934592  # 8GB
declare -a LLM_GPUS=()
hip_idx=0
for card_dev in /sys/class/drm/card*/device; do
  driver="$(basename "$(readlink "$card_dev/driver" 2>/dev/null)")"
  [[ "$driver" == "amdgpu" ]] || continue
  vram="$(cat "$card_dev/mem_info_vram_total" 2>/dev/null)"
  vram="${vram:-0}"
  bdf="$(basename "$(readlink -f "$card_dev")")"
  if (( vram >= MIN_VRAM_BYTES )); then
    LLM_GPUS+=("$hip_idx:$bdf:$((vram/1048576))MB")
    info "llm_bench: found GPU HIP$hip_idx [$bdf] vram=$((vram/1048576))MB"
  fi
  hip_idx=$((hip_idx+1))
done
n=${#LLM_GPUS[@]}
(( n == 0 )) && { fail "llm_bench" "no GPU with >=8GB VRAM found"; exit 1; }

PROMPT="Explain the theory of relativity in simple terms. Include examples and analogies that a high school student would understand."

run_one_gpu() {
  local gpu_id="$1"
  local log="$RESULTS_DIR/llm_gpu${gpu_id}.log"
  info "llm_bench: GPU $gpu_id — $MODEL_NAME"

  # Use --single-turn to avoid interactive mode hanging on stdin.
  # GGML_VK_DEVICE selects which Vulkan GPU to use.
  GGML_VK_DEVICE="$gpu_id" "$LLAMA" \
    -m "$MODEL" \
    -p "$PROMPT" \
    -n 128 \
    -ngl 99 \
    --single-turn \
    2>&1 | tee "$log"

  # Extract tokens/sec — llama.cpp prints "Generation: XX.X t/s"
  local tps
  tps="$(grep -oE 'Generation: [0-9]+\.[0-9]+ t/s' "$log" | tail -1 | grep -oE '[0-9]+\.[0-9]+')"
  if [[ -z "$tps" ]]; then
    tps="$(grep -oE '[0-9]+\.[0-9]+ tokens per second' "$log" | tail -1 | grep -oE '[0-9]+\.[0-9]+')"
  fi

  if [[ -n "$tps" ]]; then
    info "llm_bench: GPU $gpu_id — $tps tokens/sec"
    local floor="${LLM_TOKENS_PER_SEC_FLOOR:-0}"
    if (( floor > 0 )); then
      if awk -v t="$tps" -v f="$floor" 'BEGIN{exit !(t>=f)}'; then
        pass "LLM GPU$gpu_id tokens/sec" "$tps (>= $floor)"
      else
        fail "LLM GPU$gpu_id tokens/sec" "$tps (< $floor floor)"
      fi
    else
      pass "LLM GPU$gpu_id" "$tps tokens/sec ($MODEL_NAME)"
    fi
  else
    fail "LLM GPU$gpu_id" "inference failed or could not parse tokens/sec — see llm_gpu${gpu_id}.log"
  fi
}

hdr "LLM inference benchmark"
info "llm_bench: model=$MODEL_NAME  gpus=${GPU_SEL}  prompt_len=${#PROMPT}chars  gen=128 tokens"

if [[ "$GPU_SEL" == "all" ]]; then
  for entry in "${LLM_GPUS[@]}"; do
    hip_id="${entry%%:*}"
    run_one_gpu "$hip_id"
  done
else
  run_one_gpu "$GPU_SEL"
fi

info "llm_bench: done"
