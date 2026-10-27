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
- On `qwen3_5` and `qwen3_5_moe` text requests without tools or `tool_choice`,
  the JSON answer is now grammar-constrained, as on exact Flint: only one JSON
  value of the schema's shared compiled subset can be sampled, with declared
  properties as its only keys, and the end-of-turn token is masked until the
  value is complete. With the instruction alone, about 7-9% of Qwen3.5-9B
  answers broke the schema (a near-miss key, a string for an integer, prose).
  A budget that ends first, or a `stop` string that cuts the value short, is
  now a 422 `tool_noncompliance` after the content streamed, instead of a
  successful truncated answer. The prompt is unchanged, so the sidecar needs no
  new rule.
- Schemas outside the subset, tools or `tool_choice` beside the format, image
  or video input and tokenizers that fail the pinned vocabulary checks keep the
  prompt-only behavior; none of them is newly refused. While a constrained row
  decodes, other rows in the same decode step do not speculate with MTP, as
  with a `stop`, logprob or penalty row today.
