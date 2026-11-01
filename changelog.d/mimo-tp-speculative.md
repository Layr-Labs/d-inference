### MiMo V2.6 Flash tensor parallel with speculative decoding

- A MiMo V2.6 Flash tensor-parallel pair decodes with MiMo's own trained draft heads: each round checks up to two drafted tokens in one pass through the pair, so every token a round keeps shares that pass's link and weight costs.
- It is on by default: the installed provider starts both Macs' tensor-parallel workers with two drafts a round.
- Output is identical to tensor parallel without drafting, token for token and bit for bit on the synthetic checks: greedy (with or without logprobs) and sampled. Each Mac's halves stay at full 32-bit precision inside a round too, exactly as in a one-token step. Every kind of stop works inside a round. Requests with penalties or a logit bias, and sampled requests that ask for logprobs, decode one token at a time, as in the speculative pipeline.
- Each Mac holds the draft heads whole (about 2 GB more) and reserves their per-request state, and the plan counts both before it chooses tensor parallel. Two 128 GB Macs still fit, at about 100 GiB a Mac.
- Because MiMo's tensor parallel now keeps the speculative pipeline's rounds, feature parity no longer holds it back where that pipeline is the mode it would replace; its measured speed decides, and the plan credits the rounds no speed-up until they are measured. Where the plain pipeline is the mode it would replace, that pipeline's batch lanes still keep it.
- Not yet measured on a real pair: the speed-up, the heads' acceptance rate and qualification records.
