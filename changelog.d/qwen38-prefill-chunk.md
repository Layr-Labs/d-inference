### Qwen 3.8 27B: sooner first token while other requests generate

- A prompt that arrives while other Qwen 3.8 27B requests are generating is now
  prefilled in wider steps, so its first token comes sooner. Requests that are
  generating at the time pause a little longer during those steps. Prompts on an
  idle Mac are unchanged.
- `DARKBLOOM_QWEN38_PREFILL_CHUNK=0` (or `off`, `false`, `no`) restores the
  previous behaviour; the LaunchAgent forwards it.
