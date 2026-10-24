### Nemotron Super and GLM-5.3-Flash logprobs

- Nemotron 3.5 Super now serves `logprobs` and `top_logprobs` (0 to 20 alternatives) on text, image and video requests, through the coordinator and the local endpoint, streamed and complete, instead of refusing them with 400. `top_logprobs` outside 0 to 20 is still refused with 400.
- A request with logprobs decodes without speculation; requests decoding beside it keep speculating.
- `logprobs.content` has one entry per generated token in generation order, reasoning tokens included, as vLLM and SGLang return them. Joined, the entry tokens spell the reasoning text, the `</think>` marker that ends it and then the answer text, not the answer alone. Streamed reasoning chunks carry their tokens' entries, and a response that ends while the model is still reasoning (for example when `max_tokens` runs out) still returns them.
- A complete response carries the same entries as the stream. A tool call's tokens carry entries only when text follows the call; Super ends its call turns with a newline, which carries them.
- GLM-5.3-Flash logprobs, which stay disabled until the catalog lists them, follow the same contract.
