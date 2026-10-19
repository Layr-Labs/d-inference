### Deeper SSD checkpoint restores on large-memory Macs

- On Macs with at least 96 GiB, complete-checkpoint SSD restores now default
  to a 3 GiB / 2,500 ms staging cap instead of 1 GiB / 1,000 ms. With Qwen 3.8
  and MTP this restores up to 16,384 prompt tokens instead of 8,192; on an M5
  Max 128 GB a 20k-token fork's first token dropped from about 17 s to 6 s
  (27 s cold). Explicit `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` /
  `_MS` settings still win, attention block caches keep their defaults, and
  the daily SSD write cap is unchanged.
