### Gemma 4 26B: the same checkpoint encoding before the assistant attaches

- A Gemma 4 26B QAT provider that starts without its MTP assistant (the
  assistant or the catalog metadata isn't ready yet, or memory admission
  skipped it) now keeps the assistant's two access layers native in its
  prefix-cache checkpoints, as a provider with the assistant attached does. A
  prompt that hits such a checkpoint gets the same answer either way.
- `mtp_mode = "off"` or `DARKBLOOM_CBV2_MTP=0` keeps the previous target-only
  layout.
