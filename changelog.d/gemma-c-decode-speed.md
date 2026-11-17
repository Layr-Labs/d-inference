### Faster Gemma 4 26B decoding, with the same output

- Gemma 4 26B decodes faster on M5 Macs, with exactly the same output. Its
  current build's experts now use the compiled feed-forward, its single-stream
  rounds with the speculative assistant send work to the GPU in fewer, larger
  batches, and on M5 GPUs the normalization steps around each layer's
  feed-forward run as two GPU programs instead of thirteen.
- Each change has a switch for rollback (stop and start the provider with it):
  `DARKBLOOM_GEMMA4_MTP_COMMAND_BUFFERS=0`, `DARKBLOOM_GEMMA4_COMPILED_FEEDFORWARD=0`,
  `DARKBLOOM_GEMMA4_FUSED_NORMS=0`.
