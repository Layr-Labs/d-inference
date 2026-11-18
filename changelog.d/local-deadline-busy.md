### A local request at its time limit says "busy", not "Response generation failed"

- On this Mac's local API and a pair's, your request that reaches its overall time limit (one Mac's engine safety
  limit for a request that stopped making progress, or a pair's one-hour limit for your requests) now gets a clear
  busy answer: HTTP 503 with `Retry-After: 10` and "This Mac is busy: the request reached its time limit before it
  finished. Retry in a moment." (code `capacity_busy`), or, once its stream has started, its error event in those
  words (chat completions, completions and Responses). Before, a streamed request ended "Response generation failed"
  and one that wasn't streamed got a 504 (a 500 at the legacy total limit). The answer stays this Mac's: the local
  route never passes it on to your other Macs or the network, where it would start over. Requests through Darkbloom
  are unchanged.
