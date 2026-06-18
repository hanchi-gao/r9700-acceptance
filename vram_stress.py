#!/usr/bin/env python3
"""vram_stress.py — vLLM offline-inference VRAM + memory-bandwidth stress.

Runs INSIDE the rocm-vllm container, one instance per GPU (the caller sets
HIP_VISIBLE_DEVICES). Fills VRAM via a high gpu-memory-utilisation KV cache and
keeps it full by looping generation on many long prompts, which drives sustained
HBM bandwidth and memory temperature. (plan §6)

Exit non-zero on ANY HIP/OOM/load error so the stage is judged FAIL.
"""
import argparse, os, sys, time


def log(*a):
    print("[vram_stress]", *a, flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("VRAM_MODEL", "Qwen/Qwen2.5-14B-Instruct"))
    ap.add_argument("--gpu-mem-util", type=float, default=0.95)
    ap.add_argument("--max-model-len", type=int, default=8192)
    ap.add_argument("--duration", type=int, default=120, help="seconds")
    ap.add_argument("--concurrency", type=int, default=64)
    args = ap.parse_args()

    dev = os.environ.get("HIP_VISIBLE_DEVICES", "?")
    log(f"device HIP_VISIBLE_DEVICES={dev} model={args.model} "
        f"util={args.gpu_mem_util} max_len={args.max_model_len} dur={args.duration}s")

    try:
        from vllm import LLM, SamplingParams
    except Exception as e:  # noqa
        log("FATAL: cannot import vllm:", e)
        return 3

    try:
        llm = LLM(
            model=args.model,
            dtype="bfloat16",
            gpu_memory_utilization=args.gpu_mem_util,
            max_model_len=args.max_model_len,
            enable_prefix_caching=False,  # cross-NUMA KV block faults otherwise
            enforce_eager=False,
        )
    except Exception as e:  # noqa
        log("FATAL: model load / VRAM fill failed:", e)
        return 4

    # Report VRAM occupancy if torch is available.
    try:
        import torch
        free, total = torch.cuda.mem_get_info()
        log(f"VRAM reserved {(total-free)/1024**3:.2f} GiB / {total/1024**3:.2f} GiB total")
    except Exception:
        pass

    # Build long prompts near max_model_len to keep the KV cache full.
    prompt = ("The quick brown fox jumps over the lazy dog. " * 400)
    prompts = [prompt] * args.concurrency
    sp = SamplingParams(ignore_eos=True, max_tokens=4096, temperature=0.8)

    start = time.time()
    total_toks = 0
    loops = 0
    try:
        while time.time() - start < args.duration:
            outs = llm.generate(prompts, sp)
            total_toks += sum(len(o.outputs[0].token_ids) for o in outs)
            loops += 1
            elapsed = time.time() - start
            log(f"loop {loops} t={elapsed:.0f}s tok/s={total_toks/max(elapsed,1):.0f}")
    except Exception as e:  # noqa
        log("FATAL: generation error (HIP/OOM?):", e)
        return 5

    elapsed = time.time() - start
    log(f"DONE device={dev} loops={loops} tok/s={total_toks/max(elapsed,1):.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
