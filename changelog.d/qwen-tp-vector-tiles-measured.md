### Qwen tensor-parallel verification keeps its measured weight-read tiles

- Two-Mac tensor-parallel Qwen pairs verify concurrent requests with tiles of at most five vectors per weight read again (tiles of four past five), instead of whole-cohort tiles of eight or sixteen. On two M5 Ultra Macs serving Qwen3.8 27B, four concurrent requests reach about 90 tokens per second together instead of 73, with identical outputs.
