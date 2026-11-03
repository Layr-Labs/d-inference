### Gemma 4 native dispatch efficiency

- Adopt the SDK's shared dense GeGLU reuse and scoped command-buffer tuning for eligible Gemma 4 models, preserving numerical expressions, parameter contracts, paged attention, prefix caching and SSD write policy.
- An initial warm 8K, single-request endpoint screen on one M5 Max measured a 3.5–3.9% decode-proxy improvement with matching outputs. Broader concurrency, prefill, clustering and other hardware remain unmeasured; memory and admission safeguards are unchanged.
