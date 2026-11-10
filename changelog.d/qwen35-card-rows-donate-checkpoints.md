### Qwen 3.5/3.6 requests that cannot speculate save prefix checkpoints again

- The `Qwen3.5-9B`, `qwen3.5-35b-a3b` and `qwen3.6-35b-a3b-vl-mtp-mxfp8` builds give a request without a `presence_penalty` the model card's 1.5, and a request with a penalty cannot speculate. Their MTP head keeps each request's prompt history, and since 0.10.5 a request that could not speculate recorded none, so it saved no SSD or resident prefix checkpoint. A repeated prompt or the next turn of a conversation was prefilled again from the start, and the coordinator saw no cache holders for these builds.
- Such a request now records the head's prompt history and saves the same checkpoints a speculating request saves. That covers the card's penalty, any other penalty, a `stop` string, logprobs, `logit_bias` and a token constraint. The penalty and its sampling are unchanged, and the request still never speculates.
- A request that restores one of these checkpoints answers exactly as without the cache, tokens and logprobs alike, whether it speculates or not.
- From the SDK pin `libs/mlx-swift-lm` (Layr-Labs/mlx-swift-lm#398, which carries #397).
