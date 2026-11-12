### `darkbloom status` lists the answers in progress on a Mac that serves only you

- A Mac that serves only you (`darkbloom start --local`) now lists its answers
  in progress under `darkbloom status` (and in `status --json`), as a Mac that
  serves Darkbloom does: before, its state file never carried them, so a long
  local answer looked like nothing was running (0.10.12 W1). Its standalone
  server samples the counters its engines already keep, at most every 2 s.
- A pair that serves only on its local API (`darkbloom cluster local`) still
  lists none: its serving process writes no state file yet.
