### Gemma 4 26B: two draft tokens per round on M5 Ultra and M3 Ultra

- On M5 Ultra, Gemma 4 26B QAT now drafts two tokens per speculative round
  while one or two requests decode; on M3 Ultra, while one request decodes
  alone. More requests decode without speculation, and other chips keep the
  one-draft policy for a request decoding alone.
- `DARKBLOOM_GEMMA_MTP_TWO_DRAFTS=0` (or `off`, `false`, `no`) restores the
  one-draft policy on every chip; the LaunchAgent forwards it.
