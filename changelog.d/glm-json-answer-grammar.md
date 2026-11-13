### GLM-5.3-Flash JSON answers can be grammar-constrained

- With `DARKBLOOM_GLM_JSON_ANSWERS=1`, a GLM-5.3-Flash request with a JSON `response_format` (and no tools) is sampled under the same JSON grammar as Qwen, Bonsai and Lightning answers: the answer is one JSON value of the requested schema, so a missing required key, an invented key or a wrong type can no longer be generated (about 7 % of GLM's answers missed under batching, each a 422 after the streamed reasoning).
- Requests the grammar does not cover keep today's prompt-steered, checked answer; a cluster pair is never constrained. The provider's MLX runtime now accepts token constraints on GLM's native engine.
