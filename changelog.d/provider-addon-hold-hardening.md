### Add-on hold hardening

- A model load already running when an add-on hold begins, such as a local
  request's cold load, no longer installs its model afterwards. No load starts
  while held, a running one ends with a retryable 503, and the hold reports
  `held` only once it has unwound.
- Releasing a hold while its 120-second bound is cancelling leftover requests
  no longer cancels or loses track of work accepted after the release.
- A hold that unloads a native MiMo or Nemotron Super model keeps
  `loaded-models.json`, so the next start still preloads it.
- The add-on socket verifies a connection's signer before the connection takes
  one of its 8 slots, so unsigned programs cannot keep the add-on out, and a
  request line must finish within 10 seconds.
- The hold record and `darkbloom addon` mailbox files are read without blocking:
  a FIFO at their paths is refused instead of stalling the provider.
