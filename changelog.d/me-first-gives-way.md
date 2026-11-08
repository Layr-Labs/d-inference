### Me first: Darkbloom requests that haven't answered make room for yours

- On a Mac that serves both with me first on, a request of yours that has to wait for this Mac's memory, or its room
  for requests, no longer waits behind Darkbloom requests that haven't sent any output. Those go back to the network,
  which serves them on another Mac: they end with the typed `capacity / 503 / draining` refusal, which coordinators
  re-route before anything reaches the client and don't count against this Mac. Darkbloom requests that have started
  answering still finish.
- Your request then waits only for requests already answering, Darkbloom's or your own, up to the engine's 120 s
  admission lease, as before.
- Nothing changes with `--no-me-first`, or on a pair.
