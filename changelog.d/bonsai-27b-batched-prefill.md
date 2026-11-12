### Bonsai 2 27B processes prompts at full speed again on a single Mac

- Since provider 0.10.5, a single Mac ran every prompt row of Bonsai 2 27B through the one-row kernel. That kept each row's arithmetic identical to decode, but made prompt processing 2.3 to 6 times slower than in 0.10.4: about 100 tokens per second on an M5 Max instead of 620, and about 76 to 96 instead of 220 on M1 to M4 Macs. Image and tool prompts of 1,000 to 2,000 tokens or more then missed their first-token deadline, and OpenRouter saw 429s.
- Now a single Mac processes a Bonsai 2 27B prompt with one batched matrix multiply per projection again, as in 0.10.4 (TF32 on M5, FP32 elsewhere). Prompt rows are no longer bit-identical to the decode arithmetic, as before 0.10.5. Decode is unchanged.
- Pairs keep the per-row arithmetic, because both Macs must compute the same bytes. Their arithmetic receipt (`bonsai-fp32-row-arithmetic-v2`) is unchanged.
- `libs/mlx-swift` moves to `1b3520fe94` (Layr-Labs/mlx-swift#70, on the fork's `release/provider-0.10.12` = the previous pin `c633d221d6`). Only Swift sources change there, so `mlx.metallib` is unchanged.
