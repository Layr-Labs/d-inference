### Gemma 4 26B: on M5 Ultra, long prompts decode without speculation

- On M5 Ultra, a Gemma 4 26B QAT request whose prompt holds more than 16,384
  tokens no longer drafts while it decodes alone: those steps run ordinary
  chained decode, with the tokens of decode without MTP. On these prompts a lone
  request's two-draft rounds cost more than they gain. Beside a shorter request
  it follows the chip's usual table (on M5 Ultra two decoding requests already
  decode without drafts), so it never stops another request from drafting.
  Shorter prompts and other chips are unchanged.
- `DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS=0` (or `off`, `false`, `no`) lets every
  prompt draft again; a positive integer moves the limit. The provider's
  launchd job forwards it.
