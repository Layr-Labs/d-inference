### Qwen tensor-parallel decode wastes less time per token

- A Qwen pair now hands each token's work to the GPU every eight layers instead of after every layer, so the GPU spends less time waking up and waiting. On two M5 Ultras a token took about 15 % less time for one request and about 13 % less for four at once. The output is unchanged.
