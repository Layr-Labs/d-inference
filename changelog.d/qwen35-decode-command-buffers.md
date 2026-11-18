### Faster Qwen 3.5 and 3.6 decoding, with the same output

- Decode steps that don't speculate on Qwen 3.6 35B-A3B, Qwen 3.5 35B-A3B,
  Qwen 3.5 9B and Qwen 3.8 27B now send work to the GPU in fewer, larger
  command buffers, as GPT-OSS, Nemotron and Gemma 4 already do. Outputs are
  bit-identical (checked against 0.10.15). On an M5 Ultra, Qwen 3.6 35B-A3B
  decodes 19 % faster with one request (133.7 to 159.5 tokens per second),
  9 % with four and 8 % with eight.
- Rollback: set `DARKBLOOM_QWEN35_DECODE_COMMAND_BUFFERS=0`, then stop and start
  the provider.
