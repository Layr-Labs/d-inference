### SSD restore no longer waits behind another request's prefill

- Restoring a complete prefix checkpoint from SSD no longer blocks on MLX's
  process-wide eval lock while the engine runs another request's prefill
  chunk. On an M5 Max with Qwen 3.8 27B, staging a 0.96 GB checkpoint during a
  concurrent prefill dropped from 2.6–3.8 s to about 0.35 s.
- Added the opt-in `ModelCheckpointRestoreContentionLiveTests` real-model
  regression, which requires SSD restore to reach its demanded boundary, never
  to produce its first token later than cold prefill, idle or contended, and to
  stage as fast contended as idle.
