### Qwen forced tool calls can keep the caller's thinking setting

- Added opt-in `DARKBLOOM_QWEN_FORCED_TOOL_THINKING` for qwen forced-call thinking. Forced required/named tool requests retain the caller’s resolved thinking setting. Nested reasoning.enabled takes precedence over enable_thinking and effort. The existing native router separates reasoning before validating a trailing tool call. Default-off behavior is unchanged.
