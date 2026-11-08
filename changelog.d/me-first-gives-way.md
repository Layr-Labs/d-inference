### Me first: queued Darkbloom requests make room for yours

- On a Mac that serves both with me first on, a request of yours that has to wait for this Mac's memory, or its room
  for requests, no longer waits behind Darkbloom requests still queued here. Those go back to the network: they end
  with the typed `capacity / 503 / draining` refusal, which doesn't count against this Mac. Each is served by another
  Mac, or gets a retryable "busy" error (429) if the whole network is full. Darkbloom requests this Mac has started,
  in their prompt or answering, still finish.
- Your request then waits only for requests this Mac has started, Darkbloom's or your own, up to the engine's 120 s
  admission lease, as before.
- Nothing changes with `--no-me-first`, or on a pair.
