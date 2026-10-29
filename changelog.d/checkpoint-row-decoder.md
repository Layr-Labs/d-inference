### Cache restores finish sooner

- Restoring a prefix-cache checkpoint decodes its older attention rows from the
  default `balanced` checkpoint precision on the CPU. The decoder now checks each
  row for values its native type cannot hold once per row instead of once per
  eight values, with the same bytes and the same refusals. On Gemma 4 26B
  follow-up requests served from the SSD cache, time to first token fell by about
  0.2 s per restore (about 25% over an 11-request conversation on an M3 Ultra),
  and responses that save a checkpoint also end about 0.2 s sooner. Output is
  unchanged.
