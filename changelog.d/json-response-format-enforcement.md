### JSON response formats answer without Qwen thinking

- A chat request with a JSON `response_format` (`json_object` or `json_schema`)
  on the Qwen 3.5, 3.6 and 3.8 template family now renders the no-thinking
  prompt unless the caller supplies a thinking control (`reasoning.enabled`,
  `enable_thinking`, `chat_template_kwargs.enable_thinking`, any reasoning
  effort or a positive `reasoning.max_tokens` budget). The templates think by
  default, and the reasoning block regularly
  spent the caller's `max_tokens` before the JSON answer began: on Qwen3.5-9B,
  47-79% of JSON requests with a 2,048-token budget returned empty content.
- The coordinator prompt sidecar must mirror this rule for cache planning; the
  regenerated public prompt vectors change only the Qwen-family JSON cases.
