### Your own requests wait as long as it takes

- On this Mac's local API (and `--local`), a request that can't start because your other requests hold the memory
  now waits in arrival order for as long as it takes, instead of a busy 503 after 120 seconds. This includes a short
  request behind another request's long prompt: one Mac prefills one prompt at a time, and the engine's 120-second
  admission limit used to end the short one with "This Mac is at capacity"; it is now submitted again and served.
  Only a request that could never fit, even with nothing else running, is still refused at once.
- To get the busy answer sooner, bound the wait: `DARKBLOOM_LOCAL_MEMORY_WAIT_SECONDS=<seconds>` for every request
  (`0` refuses at once; `darkbloom start` passes it to the launchd provider), or the header
  `X-Darkbloom-Max-Wait: <seconds>` on one request. The shorter bound wins.
- On a two-Mac pair's local API, your requests run for up to an hour, the longest the pair's workers take, instead
  of the setup's request deadline. Requests through Darkbloom are unchanged.
