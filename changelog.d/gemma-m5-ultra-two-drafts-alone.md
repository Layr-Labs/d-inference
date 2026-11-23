### Gemma 4 26B: on M5 Ultra, two draft tokens only while one request decodes

- On M5 Ultra, Gemma 4 26B QAT now drafts two tokens per speculative round only
  while one request decodes, as on M5 Max and M3 Ultra. With two or more
  requests decoding it runs ordinary decode without speculation.
- `DARKBLOOM_GEMMA_MTP_TWO_DRAFTS=0` still restores the one-draft policy on
  every chip.
