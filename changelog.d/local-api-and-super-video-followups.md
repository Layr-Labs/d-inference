### Local API and Super video follow-ups (security)

- A `/v1/chat/completions/batch` body with more than 64 requests is refused
  (`batch_too_large`) before its requests are decoded.
- When a cancelled or drained Nemotron 3.5 Super video leaves a frame read
  running past the drain wait, the provider log says so in one fixed line; the
  request's memory charge still returns when the read ends.
