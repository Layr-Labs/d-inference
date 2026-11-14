### Bounded queue of coordinator requests awaiting admission

- Coordinator requests read off the connection hold their ciphertext until
  their admission returns, and nothing bounded how many could wait: while
  admission was stalled behind a serial model load, requests that expired or
  were cancelled and retried kept arriving and stayed buffered. At most 64
  requests and 512 MiB of ciphertext now wait at once; a request past that is
  refused on arrival with `queue_full` (capacity 429, as the engine's own
  queue refuses; retried elsewhere) and its service reservation released. The
  connection reader never waits for room, so cancels, attestation challenges
  and trust updates keep flowing.
