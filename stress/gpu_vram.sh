#!/usr/bin/env bash
# stress/gpu_vram.sh — fill VRAM + drive memory (HBM) temp on every GPU.
# One container per GPU, each pinned with HIP_VISIBLE_DEVICES, running
# vram_stress.py inside the rocm-vllm image. (plan §6)
#
# Usage: ./stress/gpu_vram.sh [--duration SECONDS]
# Every healthy card must fill ~32GB. Judged later from telemetry.csv +
# each container's exit code (non-zero => FAIL).

set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/../lib/common.sh"
source "$REPO_ROOT/lib/thresholds.sh"

DURATION=120
[[ "${1:-}" == "--duration" ]] && DURATION="${2:-120}"
MODEL="${VRAM_MODEL:-Qwen/Qwen2.5-14B-Instruct}"

if ! docker image inspect "$VRAM_IMAGE" >/dev/null 2>&1; then
  die "vLLM image not present. FIX: docker pull $VRAM_IMAGE"
fi

trap cleanup_tracked EXIT INT TERM

GPU_ARGS="$(docker_gpu_args)"
n="$(gpu_count)"
names=()
for id in $(seq 0 $((n-1))); do
  cname="vram_stress_gpu${id}"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  docker run -d --name "$cname" $GPU_ARGS \
    -e HIP_VISIBLE_DEVICES="$id" \
    -e VRAM_MODEL="$MODEL" \
    -v "$REPO_ROOT/vram_stress.py:/vram_stress.py:ro" \
    "$VRAM_IMAGE" \
    python3 /vram_stress.py --duration "$DURATION" --gpu-mem-util 0.95 \
       --max-model-len 8192 --concurrency 64 >/dev/null
  track_container "$cname"
  names+=("$cname")
  info "  launched VRAM stress container on GPU$id ($cname)"
done

# Wait for all containers, collect logs + exit codes.
rc_total=0
for cname in "${names[@]}"; do
  code="$(docker wait "$cname" 2>/dev/null || echo 1)"
  docker logs "$cname" > "$RESULTS_DIR/${cname}.log" 2>&1 || true
  docker rm -f "$cname" >/dev/null 2>&1 || true
  if [[ "$code" == "0" ]]; then
    pass "VRAM stress $cname" "exit 0"
  else
    fail "VRAM stress $cname" "exit $code (see $RESULTS_DIR/${cname}.log)"
    rc_total=1
  fi
done

info "gpu_vram: all containers finished"
exit $rc_total
