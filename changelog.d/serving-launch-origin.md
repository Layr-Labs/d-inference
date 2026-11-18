### Network serving runs only as Darkbloom's background service

- Darkbloom now serves network traffic only as its background service. `darkbloom start --foreground` no longer serves network traffic: start the service with `darkbloom start` (`darkbloom start --local --here` still serves this Mac only, in a terminal). A copy started any other way says so, asks the background service to start, and exits. Two-Mac clusters, updates, rollback and crash recovery work as before.
- To use Nemotron 3.5 Super on your own Mac only, run the service with its local endpoint (`darkbloom start --local-endpoint`) instead of `darkbloom start --foreground --local-endpoint`.
