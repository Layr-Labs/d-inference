### Gemma 4 26B: on M5 Ultra, two draft tokens only while one request decodes

- On M5 Ultra, Gemma 4 26B QAT now drafts two tokens per speculative round only
  while one request decodes, as on M5 Max and M3 Ultra. With two or more
  requests decoding it runs ordinary decode without speculation.
- `DARKBLOOM_GEMMA_MTP_M5_ULTRA_LONE_ROW=0` (or `off`, `false`, `no`) restores
  the earlier M5 Ultra behaviour, two draft tokens with one or two requests
  decoding; the LaunchAgent forwards it. `DARKBLOOM_GEMMA_MTP_TWO_DRAFTS=0` still
  restores the one-draft policy on every chip.
