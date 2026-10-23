### Local HTTP API parity

- Standalone chat now preserves scalar stop strings and explicit `min_p`, and reports captured logprobs and reasoning-token usage through the same JSON/SSE plumbing as cluster chat.
- Keep selected-mode logprob refusal before cluster reservation. Model-free parity tests use explicit capable fixtures and separately verify unsupported-mode refusal; they do not qualify native capture or model output.
