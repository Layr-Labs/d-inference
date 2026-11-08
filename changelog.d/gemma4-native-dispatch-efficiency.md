### Gemma 4 native dispatch efficiency

- Adopt the SDK's shared dense GeGLU reuse for eligible Gemma 4 models, preserving numerical expressions, parameter contracts, paged attention, prefix caching and SSD write policy. Gemma 4's decode command-buffer limits are unchanged by this entry.
- An initial warm 8K, single-request endpoint screen on one M5 Max measured a 3.5–3.9% decode-proxy improvement with matching outputs, together with an earlier scoped command-buffer limit that has since been replaced, so the gain is not attributed to the GeGLU change alone. Broader concurrency, prefill, clustering and other hardware remain unmeasured; memory and admission safeguards are unchanged.
