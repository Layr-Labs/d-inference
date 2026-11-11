### A pair's first answer after the other Mac's part stops is its typed 503, at once

- When the part of the pair on the Mac that runs the pair's API stops or starts again (a stop, a restart, an update, a
  crash) while that Mac stays on the cable, every request, the first one included, now gets a `503` with `code`
  `pair_api_unavailable` and `Retry-After: 10` at once, on that Mac and through the other Mac's port alike. Before, the
  first ones got `{"error":{"type":"invalid_request_error","message":"Provider capacity is temporarily unavailable."}}`
  with no code, once after 19 seconds. The pair's API now answers "The pair's API takes no requests right now: the pair
  is starting or stopping. Requests resume when it serves, …" while its pair doesn't serve, never holding a request until
  it does, and a request made during the pair's warm-up request is refused at once instead of waiting for it.
- Both `503`s a pair's other Mac answers (`pair_mac_unreachable` and `pair_api_unavailable`), and the pair's API's own,
  now end the same way: "…, or run `darkbloom stop`, then `darkbloom start --solo`, to serve this Mac alone (`darkbloom
  start --solo` by itself is refused while this Mac's part of the pair holds its serving lock: up to 15 minutes after
  the other Mac last answered over the cable)."
- Through the other Mac's port, a key it can't judge (another key in the local key format, such as the leading Mac's
  own, which works through it while that Mac is there) gets the same `503` without the other Mac's name, instead of a
  `401`. A missing key, one without `Bearer`, or one that isn't a local key still gets the `401`.
- While the pair's API on the leading Mac starts again, the other Mac's port stays up and answers those `503`s, instead
  of refusing connections until that API is back, and its `darkbloom status`, `darkbloom local` and `darkbloom doctor`
  say "Local API: http://127.0.0.1:<port>/v1 on this Mac answers 503 for now." with the `503`'s words, instead of "not
  listening on this Mac yet".
- A local request waiting for one of the pair's lanes when a stop or an update begins gets the same `503`, instead of a
  `429`. A request without a key that reaches the pair's API while it stops gets the API's `401`, instead of a `503`.
