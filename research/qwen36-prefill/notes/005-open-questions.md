# 005 — Open questions (must be answered with Mac numbers)

Status: open

1. What is B=1 / B=2 / B=4 aggregate prefill tok/s **on this M3 Max**
   with installed 0.8.10, High Power, CBv2, contiguous KV, text-only?
2. Does Qwen packed prefill **actually execute** as one `[B, L]`
   forward, or does EngineLoopV2 still walk rows? (`packedPrefillActivity()`)
3. Are 8K chunks 512 or 2048 on solo vs burst? Stripe is solo-only
   by design — B=4 may still be 512 and pay 16 weight streams.
4. Does QMM stay 4-bit or materialize bf16? This decides whether
   B=1 2.5× is legal.
5. What is GPU busy / wall at B=1 8K? If ~1.0, wavefront is the
   structural 2×.
6. What allocated 164 GiB on 2026-08-21? Reproduce the shape in
   a dry budget, not on device.
7. Is v0.8.8 GDN fusion still a decode killer on 0.8.10 + this
   snapshot, or was that a pin/regression combo?
8. Coordinator admission: if we change chunk/stripe, does
   `freeMemoryAdmits` / token-budget still match the provider?

Do not start kernel work before 1–5 have rows in `results.tsv`.
