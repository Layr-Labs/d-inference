### Gemma 4 26B: two draft tokens per round for one or two requests

- With one or two requests decoding, Gemma 4 26B QAT now drafts two tokens
  per speculative round instead of one, which was faster there. With three
  or more requests the engine decodes without speculation, as before.
- `DARKBLOOM_GEMMA_MTP_TWO_DRAFTS=0` (or `off`, `false`, `no`) restores the
  one-draft policy for a request decoding alone; the LaunchAgent forwards it.
