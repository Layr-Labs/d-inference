### Your own requests on a two-Mac pair wait for their first token

- On a pair's local API (the leading Mac's endpoint and `darkbloom cluster local`), a request no longer fails with
  "Response generation failed" when its first token takes longer than the pair's first-token allowance (10 s plus a
  share per prompt token). The pair prefills one prompt at a time, so a short request sent while another request's
  long prompt was prefilling, or the first request after a long idle, used to fail that way after 10–16 s; it now
  waits and is served, bounded by its request deadline.
- Requests from Darkbloom keep the allowance, including your own that reach the pair through Darkbloom (self-route).
  `DARKBLOOM_LOCAL_FIRST_TOKEN_WAIT=0` restores it for local requests; `darkbloom start` passes it to the launchd
  provider.
