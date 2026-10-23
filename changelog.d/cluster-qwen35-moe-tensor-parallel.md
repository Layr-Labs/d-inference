### Qwen 3.5 MoE equal-share tensor parallelism

- Added verified two-rank tensor-parallel loading for the registered Qwen3.5
  35B A3B text target at equal shares, including canonical fused expert-bank
  slicing and a routed-block arithmetic agreement. Qwen3.6 and unequal routed
  shares remain excluded; placement still compares measured execution costs.
