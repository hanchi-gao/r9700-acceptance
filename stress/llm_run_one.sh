#!/usr/bin/env bash
# Helper: run llama-cli on one GPU, output result to a file.
# Usage: llm_run_one.sh <model> <gpu_id> <output_file>
set -uo pipefail

MODEL="$1"
GPU_ID="$2"
OUTFILE="$3"

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
LLAMA="$REPO_ROOT/build/llama-cli"

export GGML_VK_DEVICE="$GPU_ID"

# Use -no-cnv and pipe prompt via stdin to avoid interactive mode issues
"$LLAMA" -m "$MODEL" \
  -p "Explain the theory of relativity in simple terms." \
  -n 128 -ngl 99 -no-cnv \
  < /dev/null \
  > "$OUTFILE" 2>&1

echo "__EXIT_CODE=$?" >> "$OUTFILE"
