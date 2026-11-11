### Nemotron Super's prompt cache now restores exactly

- Nemotron Super's prompt cache now restores exactly: an answer from a cached prompt is the answer the same prompt gets without the cache. Super now saves its prompt checkpoints at native precision. Before, they used the provider-wide `balanced` default, which stores older attention rows at 4 bits.
- Measured on the production weights on an M5 Ultra, with 3 reasoning prompts of about 8,600 tokens restored from an 8,192-token checkpoint: `balanced` checkpoints changed all 3 answers, and native checkpoints matched the uncached answers bit for bit in all 3, tokens and logprobs alike.
- Checkpoints are larger. At 8,192 tokens one is about 249 MB instead of 204 MB, so about 15 % more is written per prompt; at 30,720 tokens it is about 457 MB instead of 285 MB. The SSD cache keeps its shared disk budget, so it holds fewer Super checkpoints.
- Super's own per-model setting or the process switch still selects another precision. A global setting, even an explicit `k4v4`, `k8v4` or `k8v8`, no longer applies to Super. Existing Super checkpoints stop matching and age out within their 30-minute lifetime.
