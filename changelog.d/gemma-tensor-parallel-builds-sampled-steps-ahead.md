### Gemma tensor parallel prepares the next token ahead for sampled requests too

- Requests that sample (temperature above 0, with or without logprobs), and greedy requests with logit bias or penalties, now also start the next token's work on the GPU before the last token is read. Each token is still the exact draw for its position and seed, so the output is unchanged (except that a request that already fails because one Mac stopped on its own may stream one extra token first, as on GLM). Greedy requests that ask for logprobs keep the old order.
