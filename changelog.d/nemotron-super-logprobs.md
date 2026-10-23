### Nemotron Super logprobs

- Nemotron 3.5 Super now serves `logprobs` and `top_logprobs` (0 to 20 alternatives) on text, image and video requests, through the coordinator and the local endpoint, streamed and complete, instead of refusing them with 400. `top_logprobs` outside 0 to 20 is still refused with 400.
- A request with logprobs decodes without speculation; requests decoding beside it keep speculating.
