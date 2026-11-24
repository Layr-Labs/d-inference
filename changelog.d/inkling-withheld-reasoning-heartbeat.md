### Inkling 2 streams with reasoning off start sooner

- When a streamed Inkling 2 request turns reasoning off, the model still
  thinks before it answers and that thought is withheld. The provider now
  sends one empty `content` delta (`{"content": ""}`, no role) when it starts
  withholding, so the stream shows progress before the answer. The delta
  carries nothing from the withheld thought. Reasoning-on streams, other
  models and non-streamed responses are unchanged.
