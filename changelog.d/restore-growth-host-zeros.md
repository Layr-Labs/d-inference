### Provider-staged prefix restores grow their remaining KV backing like new requests

- A request restored from a complete prefix checkpoint (the provider-staged,
  non-native path) gets paged KV backing for the rest of its maximum length when
  the restore is published. That growth created every new segment with a GPU
  zero fill and a stream fence. New requests already grow from
  zero-fill-on-demand host pages when segment retention and
  `DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS` are on (the default). A restored request
  that asked for a long maximum length waited for that fill before its first
  prefill launch: about 1 ms at maximum lengths up to 16K, rising to about
  180 ms above 64K in one profiled workload (Qwen 3.8 27B, M5 Ultra).
- Restores now grow the same way new requests do (mlx-swift-lm `main` at
  `3a73162c`, which carries this fix). Segments whose size is not a whole number of
  VM pages, native-bound restores and `DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS=0` keep
  the device fill. Outputs and the accounting rules are unchanged; measured
  allocation footprints can differ.
