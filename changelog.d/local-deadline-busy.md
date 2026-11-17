### A local request at its time limit says "busy", not "Response generation failed"

- On this Mac's local API and a pair's, your request that reaches its overall time limit (one Mac's engine safety
  limit for a request that stopped making progress, or a pair's one-hour limit for your requests) now gets a clear
  busy answer: HTTP 503 with `Retry-After: 10` and "This Mac is busy: the request reached its time limit before it
  finished. Retry in a moment." (code `capacity_busy`), or, once its stream has started, an error chunk in those
  words. Before, the client got "Response generation failed" or a 500. Requests through Darkbloom are unchanged.
