### GLM tensor-parallel prefill: 8K micro-batches on long prompts

- Long prompts on a GLM-5.3-Flash tensor-parallel pair prefill in 32K-token graphs with 8,192-row micro-batches where every micro-batch's cross-Mac sums stay hidden behind the rest of the graph; shorter prompts keep their current plan. Prompt prefixes are still kept every 4,096 tokens, and DSA top-k selection keeps each row's original candidates, so outputs are bit-identical. A 31.5K-token prompt prefills about 4 % faster on two M5 Ultra.
