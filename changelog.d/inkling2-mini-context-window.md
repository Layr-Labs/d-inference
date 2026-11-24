### Inkling 2 Mini serves a 40,960-token window

- `thinkingmachines/Inkling-2-Mini` now serves 40,960 tokens of prompt plus
  output (the checkpoint declares 1,048,576). Before, every request whose
  prompt plus `max_tokens` passed 41,432 tokens failed at once with HTTP 500
  ("Inference generation failed"; streamed, a 200 then an error chunk): the
  DSpark drafter's per-request pool was granted less than the paged pool's
  segments charge. Now an output that would pass the window is cut to what
  the prompt leaves, and a prompt of 40,960 tokens or more is refused as a
  context error (HTTP 400 `context_length_exceeded`).
