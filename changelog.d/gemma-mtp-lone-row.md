### Gemma 4 26B: speculative decoding only while one request decodes

- With two or more requests decoding at once, Gemma 4 26B QAT now runs plain
  chained decode instead of occasional one-token MTP rounds, which were 1-4 %
  slower than plain decode there on an M5 Ultra. Two, four and eight requests
  now decode at plain speed; a lone request keeps MTP (about 15 % faster than
  plain on an M5 Ultra).
- `DARKBLOOM_GEMMA_MTP_LONE_ROW=0` (or `off`, `false`, `no`) restores MTP at
  two to four requests; the LaunchAgent forwards it.
