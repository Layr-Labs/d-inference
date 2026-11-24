### Gemma 4 26B: on M5 Ultra, long prompts decode without speculation

- Off by default in this release: setting `DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS`
  to a positive integer (16,384 is the measured value) turns it on. Then, on M5
  Ultra, a Gemma 4 26B QAT request whose prompt holds more than the limit no
  longer drafts while it decodes alone: those steps run ordinary chained decode,
  with the tokens of decode without MTP. On these prompts a lone request's
  two-draft rounds cost more than they gain. Beside a shorter request it follows
  the chip's usual table (on M5 Ultra two decoding requests already decode
  without drafts), so it never stops another request from drafting. Shorter
  prompts and other chips are unchanged.
- `DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS=0` (or `off`, `false`, `no`) keeps it
  off. The provider's launchd job forwards the setting.
