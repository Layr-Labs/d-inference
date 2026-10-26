### Local HTTP API parity

- Standalone chat now preserves scalar stop strings and explicit `min_p`, and reports captured logprobs and reasoning-token usage through the same JSON/SSE plumbing as cluster chat.
- Model-free parity tests compare the two local APIs; they do not qualify native capture or model output.
