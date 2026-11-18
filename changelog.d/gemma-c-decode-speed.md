### Faster Gemma 4 26B decoding, with the same output

- Gemma 4 26B decodes faster with exactly the same output. Its current build's
  experts now use the compiled feed-forward, and its single-stream rounds with
  the speculative assistant send work to the GPU in fewer, larger batches. On a
  quiet M5 Ultra one stream decodes 1.8 % faster than in 0.10.14 (154.8 vs 152.1
  tokens per second); eight streams are unchanged.
- Each change has a switch for rollback (stop and start the provider with it):
  `DARKBLOOM_GEMMA4_MTP_COMMAND_BUFFERS=0`, `DARKBLOOM_GEMMA4_COMPILED_FEEDFORWARD=0`.
