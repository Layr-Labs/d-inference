### MiMo V2.6 Flash tensor parallel with speculative decoding

- A MiMo V2.6 Flash tensor-parallel pair can decode with MiMo's three trained draft heads: each round checks up to three drafted tokens in one pass through the pair, so every token a round keeps shares that pass's link and weight costs.
- It is off by default. Only a worker launched by hand with `--mtp-depth` uses it: the installed provider never passes that flag to a MiMo tensor-parallel worker, and the planner does not count it.
- Output is identical to tensor parallel without drafting, token for token and bit for bit on the synthetic checks: greedy (with or without logprobs) and sampled. Every kind of stop works inside a round. Requests with penalties or a logit bias, and sampled requests that ask for logprobs, decode one token at a time, as in the speculative pipeline.
- Each Mac holds the draft heads whole (about 2 GB more, still within two 128 GB Macs) and reserves their per-request state.
- Not yet measured on a real pair: the speed-up, the heads' acceptance rate and qualification records.
