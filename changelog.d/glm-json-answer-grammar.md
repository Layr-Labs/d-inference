### GLM-5.3-Flash JSON answers follow the schema

- A GLM-5.3-Flash request with a JSON `response_format` (and no tools) is now sampled under the same JSON grammar as Qwen, Bonsai and Lightning answers: the answer is one JSON value of the requested schema, so a missing required key, an invented key or a wrong type can no longer be generated (about 7 % of GLM's answers missed under batching, each a 422 after the streamed reasoning).
- Requests the grammar does not cover keep today's prompt-steered, checked answer; a cluster pair is never constrained. The provider's MLX runtime now accepts token constraints on GLM's native engine.
- A constrained GLM request decodes without speculative drafting (MTP), and so does a request sharing a two-request decode step with it (GLM drafts with at most two); it also reuses no cached prompt prefix of another JSON request.
- `DARKBLOOM_GLM_JSON_ANSWERS=0` restores the prompt-steered, checked answer.
