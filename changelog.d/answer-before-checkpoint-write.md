### A response ends when its answer is complete, before its checkpoint write

- A request that stores its prompt's complete checkpoint on the SSD now ends its response as soon as the answer is
  complete; the checkpoint is written afterwards. Before, the response's end (finish reason, usage, `[DONE]`) waited
  for the write: on Gemma 4 26B prompts over 2,048 tokens that was a median of about 0.4–0.5 s on M5 Max and M5 Ultra
  and 0.6–1.1 s on other Macs, and up to about 2 s on 8K+ prompts.
- The request's rows, KV reservation and service allowance are still held until the write settles, as before.
- A follow-up that arrives before the write settles can't use that checkpoint yet: it restores an earlier one, if any,
  and prefills the rest.
- Seeded requests, Nemotron Super, and engines on the native tracked profile (GLM-5.3-Flash, MiMo), keep the old
  order.
- `DARKBLOOM_PREFIX_CACHE_SSD_TERMINAL_BEFORE_PUBLICATION=0` restores the old order for every request; set it in the
  shell for `darkbloom start`, which writes it into the provider's launchd job.
