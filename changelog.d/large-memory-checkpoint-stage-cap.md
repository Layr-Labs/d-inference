### Deeper SSD checkpoint restores on large-memory Macs

- On Macs with at least 48 GiB, complete-checkpoint SSD restores now default
  to a 7 GiB / 15 s staging cap instead of 1 GiB / 1 s. With Qwen 3.8 and MTP
  the deepest restorable prompt prefix rises from 8,192 tokens to about
  94,000. On an M5 Max 128 GB a 20k-token fork's first token dropped from
  about 17 s to 6 s (27 s cold). Explicit
  `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` / `_MS` settings still win in
  processes that receive them (LaunchAgents do not forward them), attention
  block caches keep their defaults, and the daily SSD write cap is unchanged.
