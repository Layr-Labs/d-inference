### Your own requests wait for memory instead of a 503

- On this Mac's local API (one Mac, `darkbloom start --local`, a pair's leader and `cluster local`), a request that
  can't start because requests already running hold the memory it needs now waits for them, in arrival order, and
  starts as soon as one gives its memory back, instead of an immediate 503. The wait is bounded at 120 s
  (`DARKBLOOM_LOCAL_MEMORY_WAIT_SECONDS`; `0` restores the immediate refusal), and a pair's first-token allowance
  starts after it.
- The memory 503 no longer asks for a lower `max_tokens` or a shorter prompt unless the request can't fit the Mac's
  memory even with nothing else running: a busy Mac now says it is at capacity and sends `Retry-After`, so agents
  such as Hermes no longer read it as a conversation too large for the model.
- Darkbloom requests are unchanged: a Mac that can't start one now still refuses it at once, so the network sends it
  elsewhere within its first-content budget.
