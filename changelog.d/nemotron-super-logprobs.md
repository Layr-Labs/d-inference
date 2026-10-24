### Nemotron Super and GLM-5.3-Flash logprobs

- Nemotron 3.5 Super now serves `logprobs` and `top_logprobs` (0 to 20 alternatives) on text, image and video requests, through the coordinator and the local endpoint, streamed and complete, instead of refusing them with 400. `top_logprobs` outside 0 to 20 is still refused with 400.
- A request with logprobs decodes without speculation; requests decoding beside it keep speculating.
- `logprobs.content` has one entry per generated token in generation order, covering reasoning, answer and tool-call tokens, as vLLM and SGLang return them. Joined, the entry tokens spell the reasoning text, the `</think>` marker that ends it and then the answer text, not the answer alone. Streamed reasoning chunks carry their tokens' entries, and a response that ends while the model is still reasoning (for example when `max_tokens` runs out) still returns them.
- A complete response carries the same entries as the stream. Tool-call tokens lack entries only when nothing follows the call, which is rare for Super: its call turns end with a newline that carries them.
- GLM-5.3-Flash logprobs, which stay disabled until the catalog lists them, follow the same contract.
