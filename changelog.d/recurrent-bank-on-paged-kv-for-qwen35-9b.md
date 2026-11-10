### Opt-in: the in-memory recurrent bank on paged KV for Qwen3.5-9B

- With `DARKBLOOM_PREFIX_CACHE_MEMORY=1`, a `Qwen3.5-9B` slot on paged KV now keeps its recurrent checkpoints in the in-memory bank. Before, paged storage hosted that bank only for Nemotron Super, so the opt-in gave this model nothing on its default backend. It stays off by default.
- A slot that hosts the bank serves it in place of its encrypted SSD checkpoints: it writes no checkpoint to disk, restores nothing after a restart, and its SSD cache status reads `disabled` / `config_disabled`. Without the opt-in the slot keeps its SSD checkpoints, as before.
- The bank is carved from the slot's KV grant: a quarter of the grant in 256 MiB steps, at most 4 GiB, and no bank when that is under 1 GiB. `DARKBLOOM_CBV2_HYBRID_PREFIX_BYTES` sets another size.
- Entries stay in RAM under the authenticated cache scope of the request that wrote them, as on contiguous storage. A request without that scope neither reads nor feeds the bank. `DARKBLOOM_PREFIX_CACHE=0` and `DARKBLOOM_CBV2_HYBRID_PREFIX_CACHE=0` turn it off.
- Only the exact `Qwen3.5-9B` artifact qualifies. Every other model on paged KV, and every model on contiguous KV, behaves as before.
