### Qwen 3.5 family: MTP rounds submit GPU work in fewer command buffers, with the same output

- MTP rounds of Qwen 3.6 35B-A3B and the other Qwen 3.5 family builds (Qwen 3.5
  35B-A3B, Qwen 3.5 9B, Qwen 3.8 27B) whose rows each carry at most 8 tokens now
  send work to the GPU in fewer, larger command buffers, as their plain decode
  steps do. Outputs are bit-identical.
- Rollback: set `DARKBLOOM_QWEN35_MTP_COMMAND_BUFFERS=0`, then stop and start
  the provider.
