### GLM-5.3-Flash serves hidden reasoning and Anthropic thinking controls

GLM-5.3-Flash refused several documented request controls with 400
`invalid_request`, and the coordinator counted each refusal as a failed job
for the provider that received it. It now serves them:

- OpenRouter's hidden reasoning (`reasoning.exclude: true`,
  `include_reasoning: false`): the model still reasons, and the reasoning is
  withheld from the response and its logprobs but billed as reasoning tokens,
  as OpenRouter documents.
- Anthropic's `thinking` object, which Darkbloom's Messages API forwards:
  `budget_tokens` selects an effort like `reasoning.max_tokens`, `adaptive`
  enables thinking, and `display: "omitted"` hides the reasoning.
- A null `reasoning_effort`, which OpenAI documents as nullable, is unset.

The prompt is unchanged in every case.
