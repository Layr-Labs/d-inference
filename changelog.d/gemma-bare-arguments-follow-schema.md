### Gemma 4 keeps a string parameter's unquoted `01000` as "01000"

- Gemma 4 sometimes writes a string argument without its quote marker. Every such value was read as JSON, so a string parameter's `01000` reached the client as the number 1000, `1.10` as 1.1, `007` as 7 and a 20-digit id as an inexact number, and a `strict` tool failed the call partway through the stream.
- Such a value is now read by the parameter's declared type, as vLLM does: a parameter that takes a string keeps the text the model wrote, at any depth. Number, integer and boolean parameters, and calls whose tools declare no types, read it as before. The SDK pin moves to mlx-swift-lm `c9471bca` (main `84580e8a` plus this change).
