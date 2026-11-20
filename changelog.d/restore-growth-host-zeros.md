### Prefix-cache restores no longer zero-fill their remaining KV backing on the GPU

- A request restored from a complete prefix checkpoint gets paged KV backing for
  the rest of its maximum length when the restore is published. That growth
  zero-filled each new segment on the GPU and waited for the queue to drain,
  even though new requests already grow from zero-fill-on-demand host pages
  (`DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS`, on by default). A restored request that
  asks for a long maximum length waited tens to hundreds of milliseconds for it
  before its first prefill launch.
- Restores now grow their backing the same way new requests do
  (mlx-swift-lm `082a2b3f`, the current SDK pin plus this fix). Outputs are
  unchanged. `DARKBLOOM_TTFT_SEGMENT_HOST_ZEROS=0` keeps the device fill for both.
