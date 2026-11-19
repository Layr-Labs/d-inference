### Gemma 4 26B: speculative decoding only while a request decodes alone

- Gemma 4 26B QAT now drafts with MTP only while one request decodes; with
  several requests at once the engine decodes them without speculation, which
  was faster there. A lone request keeps MTP.
- `DARKBLOOM_GEMMA_MTP_LONE_ROW=0` (or `off`, `false`, `no`) restores MTP for
  two to four requests (two on M1/M2); the LaunchAgent forwards it.
