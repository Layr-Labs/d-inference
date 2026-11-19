### Gemma 4 26B: speculative decoding only while one request decodes

- With two or more requests decoding at once, Gemma 4 26B QAT now runs plain
  chained decode instead of occasional one-token MTP rounds, which were
  slower than plain decode there. A lone request keeps MTP as before.
- `DARKBLOOM_GEMMA_MTP_LONE_ROW=0` (or `off`, `false`, `no`) restores MTP at
  two to four requests; the LaunchAgent forwards it.
