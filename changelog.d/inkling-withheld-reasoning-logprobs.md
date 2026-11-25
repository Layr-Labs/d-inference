### Inkling 2 Mini: no logprob entries for a declined thought

- An Inkling 2 Mini request with thinking off (`reasoning.enabled: false`,
  `enable_thinking: false` or an effort of `none`) and `logprobs: true` no
  longer returns the thought the model still writes as `logprobs` entries,
  together with Inkling's frame markers such as `<|message_model|>` and
  `<|content_thinking|>`. Only tokens of the answer and of call messages keep
  their entries, in streamed and non-streamed responses alike, on the local
  API and through the coordinator. The answer text is unchanged.
