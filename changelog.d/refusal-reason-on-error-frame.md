### A refused request tells the coordinator why

- **The `inference_error` frame of a client refusal names its reason:**
  `refusal_reason`, the closed reason `darkbloom logs` already names (such as
  `missing_user_query`, `unmatched_tool_result` or `request_exceeds_context`),
  and `refusal_message`, one fixed sentence for that reason. Neither carries
  request text. The `error` text the requester gets is unchanged ("Invalid
  inference request."); today's coordinator ignores both keys until it is
  updated to record or forward them.
- **Qwen 3.5/3.6/3.8 tool conversations name the check that refused them:** a
  conversation with no real user turn is `missing_user_query`, and a `tool`
  message with no assistant `tool_calls` before it is `unmatched_tool_result`
  (before, both logged and sent no reason). The same history checks on every
  model, GPT-OSS's and Gemma 4's included, name theirs, and required or named
  `tool_choice` with image or video input is `unsupported_forced_tool_choice`.
