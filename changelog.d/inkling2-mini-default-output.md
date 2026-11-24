### Inkling 2 Mini writes up to 65,536 tokens when a request names no max_tokens

- A request to `thinkingmachines/Inkling-2-Mini` that names no `max_tokens`
  may now write 65,536 tokens (was 32,768), cut to what its prompt leaves of
  the window. Its long reasoning often ran past 32,768 tokens and the answer
  ended as `length` before it was written. Admission reserves the prompt plus
  this output, as for any request. A request that names `max_tokens` is
  unchanged, and every other model keeps the 32,768-token default.
