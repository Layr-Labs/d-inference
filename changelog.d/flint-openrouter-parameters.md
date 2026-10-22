### Flint OpenRouter parameters

- Accept Flint reasoning effort, `reasoning.enabled` and thinking switches with no effect, since Flint always chooses whether to reason. Malformed values are still rejected. `reasoning.exclude`, `include_reasoning: false` and `reasoning.enabled: false` now hide Flint's reasoning in chat completions, the Responses API and coordinator streams; those tokens are still counted and billed, and they no longer appear in coordinator logprobs.
- Support up to four `stop` sequences on Flint, matched only against the visible answer after reasoning; reasoning and tool calls never trigger a stop.
- Enforce JSON `response_format` (`json_object` and `json_schema`) on Flint's answer after optional reasoning. Requests with tools and a response format return only the formatted answer. Output that is cut off or invalid returns 422 instead of a successful completion.
