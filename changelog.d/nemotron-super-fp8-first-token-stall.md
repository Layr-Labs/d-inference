### Nemotron Super first token no longer stalls on prompts of about 80 to 92 tokens

Nemotron 3.5 Super prefill chunks near the FP8 eager reference's 64 MiB bound (most visibly prompts of about 80 to
92 tokens, and long prompts whose last 2,048-token chunk has that many tokens) split one projection into thousands
of small products. The first token of a 92-token prompt took about 12 s on an M5 Ultra on 0.10.1 (about 3 s on the
0.10.2 MLX, about 6 s on an M3 Ultra), and concurrent requests queued behind it. The SDK now regroups those products
into at most 128 per call with the same per-output arithmetic, so the first token arrives in about 0.5 s on an M5
Ultra and about 0.9 s on an M3 Ultra, with the same outputs as before; on M5 Macs, chunks of 87 to 92 rows (and a
few longer bands) take the larger products already used for longer chunks, whose outputs can differ within
rounding.
