### Prompt-token cache batch hits

- Preserve all prompt-token cache hits present at the start of a request's batch lookup, avoiding unnecessary re-tokenization when promoting an earlier hit rotates the cache generations.
