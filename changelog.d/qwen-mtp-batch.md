### Qwen 3.5 family: several requests can speculate at once

- `DARKBLOOM_QWEN_MTP_MAX_BATCH` (read once per process, forwarded by the
  LaunchAgent) sets how many decoding requests of a Qwen 3.5-family model may
  use speculative decoding together; `1` keeps one, as in 0.10.15.
