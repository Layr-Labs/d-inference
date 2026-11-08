### LFM2.5 refuses more ignored request options

- `LiquidAI/LFM2.5-24B-A2B-MLX-4bit` and `lfm2.5-24b-a2b` now also refuse the remaining common thinking-disable spellings with HTTP 400: Anthropic `/v1/messages` `thinking: {"type": "disabled"}`, top-level `thinking: false` and `chat_template_kwargs.thinking: false`. Previously these were accepted and reasoning stayed on.
- The same ids refuse `response_format` `json_schema` and `json_object` with HTTP 400, because structured output is not enforced for this model. Previously the format was accepted and the answer was not guaranteed to conform. `text` is unaffected.
- Coordinator clients receive the standard `invalid inference request` error, which is not retried or charged. The provider's local HTTP server names the field or format. Other models are unchanged.
