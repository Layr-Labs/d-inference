### Coordinator reconnects

- After a close with code 1001 (going away) or 1012 (service restart), which the
  server side sends to every provider at once, the provider waits a random 0 to
  15 s before it reconnects, so a whole fleet does not reconnect in the same
  second.
- A new connection may wait up to 30 s for the coordinator's first frame before
  the provider counts it as dead; after that first frame the 6 s bound applies.
  A coordinator that registers many providers at once no longer makes them drop
  and reconnect again.
