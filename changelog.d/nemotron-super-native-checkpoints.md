### Nemotron Super's prompt cache now restores exactly

- Nemotron Super's prompt cache now restores exactly: an answer from a cached prompt is the answer the same prompt gets without the cache. Super now saves its prompt checkpoints at native precision. Before, they used the provider-wide `balanced` default, which stores older attention rows at 4 bits, and on the production weights that changed answers to long reasoning prompts.
- A checkpoint of 8,192 tokens grows from about 204 MB to about 249 MB on disk. The SSD cache keeps its shared disk budget.
- A per-model setting for Super or the process switch still selects another precision; the global setting no longer applies to Super. Existing Super checkpoints stop matching and age out within their 30-minute lifetime.
