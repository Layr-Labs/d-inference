"""Batched throughput benchmark for mlx_lm — apples-to-apples with our Swift
provider's PerformanceLiveTests at B=1, B=2, B=4.

Drives `mlx_lm.generate.BatchGenerator` (the same upstream API our Swift
fork ports) over a fixed long-output prompt and reports prefill+1, decode-
only tok/s, and aggregate tok/s per batch size. Use this to track the
dispatch-overhead gap between mlx-swift and mlx-lm Python.

Usage:
  /private/tmp/mlxvenv-0.31.2/bin/python scripts/mlx_lm_batch_bench.py \\
    --model mlx-community/Qwen3-0.6B-8bit --max-tokens 64 --batch-sizes 1,2,4

  /private/tmp/mlxvenv-0.31.2/bin/python scripts/mlx_lm_batch_bench.py \\
    --model mlx-community/gemma-4-26b-a4b-it-8bit --max-tokens 32 --batch-sizes 1,2,4

Reference numbers on M4 Max (mlx_lm 0.31.3, mlx 0.31.2):
  Qwen3 0.6B-8bit             B=1: 265 tok/s  B=2: 694 tok/s  B=4: 1119 tok/s
  Gemma 4 26B-A4B-it-8bit MoE B=1:  74 tok/s  B=2: 126 tok/s  B=4:  181 tok/s
"""
import sys, time, argparse
import mlx.core as mx
from mlx_lm import load
from mlx_lm.generate import BatchGenerator

PROMPT = (
    "Tell me a 200-word story about a robot that learns to paint. "
    "Be detailed and descriptive throughout."
)

def benchmark(model_id, max_tokens, batch_sizes):
    print(f"--- mlx_lm reference for {model_id} (max_tokens={max_tokens}) ---")
    model, tokenizer = load(model_id)
    chat = tokenizer.apply_chat_template(
        [{"role": "user", "content": PROMPT}],
        add_generation_prompt=True,
    )
    chat_tokens = chat if isinstance(chat, list) else tokenizer.encode(chat)
    print(f"prompt tokens = {len(chat_tokens)}")

    for B in batch_sizes:
        gen = BatchGenerator(
            model,
            max_tokens=max_tokens,
            completion_batch_size=B,
            prefill_batch_size=B,
        )
        gen.insert([chat_tokens] * B)

        # First call drains prefill -> generation transition.
        # We count tokens from the SECOND step onward so prefill is excluded.
        prefill_start = time.perf_counter()
        _ = gen.next()  # may include prefill segments + first generated tokens
        prefill_elapsed = time.perf_counter() - prefill_start

        decode_start = time.perf_counter()
        produced = 0
        target = max_tokens * B
        # Hard cap on iterations: at most max_tokens * B + B (slack) calls.
        for _ in range(target + B + 10):
            prompt_resp, gen_resp = gen.next()
            produced += len(gen_resp)
            if produced >= target:
                break
            # Heuristic stop: nothing came back this step AND nothing pending.
            if not gen_resp and not prompt_resp:
                break
        decode_elapsed = time.perf_counter() - decode_start
        gen.close()

        decode_tps = produced / decode_elapsed if decode_elapsed > 0 else 0.0
        agg_tps = produced / (prefill_elapsed + decode_elapsed) if (prefill_elapsed + decode_elapsed) > 0 else 0.0
        print(
            f"  B={B}  prefill+1: {prefill_elapsed*1000:6.1f} ms   "
            f"decode-only: {decode_tps:6.1f} tok/s   "
            f"aggregate (incl prefill): {agg_tps:6.1f} tok/s   "
            f"({produced} tokens)"
        )

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--max-tokens", type=int, default=32)
    ap.add_argument("--batch-sizes", default="1,2,4")
    args = ap.parse_args()
    benchmark(args.model, args.max_tokens, [int(x) for x in args.batch_sizes.split(",")])
