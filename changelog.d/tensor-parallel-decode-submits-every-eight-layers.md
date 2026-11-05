### Qwen tensor-parallel decode wastes less time per token

- A Qwen pair now hands each token's work to the GPU every eight layers instead of after every layer, so the GPU spends less time waking up and waiting. On two M5 Ultras a token took about 6 % less time for one request and about 16 % less for four at once, and up to 20 % less when the Mac was busy with other work. The output is unchanged.
