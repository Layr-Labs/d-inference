### MiMo V2.6 Flash tensor parallel with speculative decoding

- A MiMo V2.6 Flash tensor-parallel pair can decode with MiMo's three trained draft heads: each round checks up to three drafted tokens in one pass through the pair, so every token a round keeps shares that pass's link and weight costs. It is off by default and turned on per launch (`--mtp-depth`); the planner does not count it yet.
- Greedy output is identical to tensor parallel without drafting, token for token and bit for bit on the synthetic checks, and greedy logprobs and every kind of stop work inside a round. Sampled requests follow the speculative pipeline's rule: they draft unless they ask for logprobs or use penalties or a logit bias, in which case they decode one token at a time.
- Each Mac holds the draft heads whole (about 2 GB more, still within two 128 GB Macs) and reserves their per-request state.
- Not yet measured on a real pair: the speed-up, the heads' acceptance rate and qualification records.
