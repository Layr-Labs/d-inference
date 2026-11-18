### Faster Qwen 3.5 and 3.6 decoding, with the same output

- Qwen 3.6 35B-A3B, Qwen 3.5 35B-A3B, Qwen 3.5 9B and Qwen 3.8 27B decode faster
  with exactly the same output: their decode steps send work to the GPU in
  fewer, larger batches, as GPT-OSS, Nemotron and Gemma 4 already do.
- Rollback: stop and start the provider with
  `DARKBLOOM_QWEN35_DECODE_COMMAND_BUFFERS=0`.
