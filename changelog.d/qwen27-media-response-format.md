### Qwen27 media response formats

- Accept image/video `response_format` requests through the cluster's existing
  Qwen27 media path, using the same JSON prompt preparation and nonstream
  JSON/schema post-validation as standalone serving.
- Preserve forced-media-tool refusals and default processor policy. Streaming
  remains prompt-guided; this does not add token-level grammar enforcement or
  establish full-model media/schema accuracy.
