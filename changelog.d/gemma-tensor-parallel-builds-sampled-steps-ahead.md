### Gemma tensor parallel prepares the next token ahead for sampled requests too

- Requests that sample (temperature above 0, with or without logprobs) now also start the next token's work on the GPU before the last token is read. Each token is still the exact draw for its position and seed, so the output is unchanged. Greedy requests that ask for logprobs keep the old order.
