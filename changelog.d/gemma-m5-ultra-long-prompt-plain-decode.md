### Gemma 4 26B: on M5 Ultra, long prompts decode without speculation

- On M5 Ultra, a Gemma 4 26B QAT request whose prompt holds more than 4,096
  tokens no longer drafts. It decodes as ordinary chained decode for its whole
  lifetime, with the tokens of decode without MTP. On these prompts a lone
  request's two-draft rounds cost more than they gain. Shorter prompts and other
  chips are unchanged.
- `DARKBLOOM_GEMMA_MTP_MAX_PROMPT_TOKENS=0` (or `off`, `false`, `no`) lets every
  prompt draft again; a positive integer moves the limit. The LaunchAgent
  forwards it.
