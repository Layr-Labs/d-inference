### LFM2.5 refuses reasoning-disable requests

- `LiquidAI/LFM2.5-24B-A2B-MLX-4bit` and `lfm2.5-24b-a2b` always reason, so requests that ask to disable reasoning (`enable_thinking: false`, `chat_template_kwargs.enable_thinking: false`, `reasoning.enabled: false`, or `reasoning.effort` / `reasoning_effort` set to `none`) now get an HTTP 400 before the provider accepts them or loads the model, instead of being served with reasoning on.
- Coordinator clients receive the standard `invalid inference request` error; the error is not retried or charged. The provider's local HTTP server names the offending field.
- Effort hints `low`, `medium` and `high` are still accepted and have no effect; other models are unchanged.
