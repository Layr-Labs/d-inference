### Two-Mac pairs recover after a lost rank

- A two-Mac pair no longer stays unable to serve after it loses a rank, is
  fenced, or has a request cancelled before it started. The leader released
  its committed start only after the old pair slot had fully drained. When the
  drain outlasted the session's own wait, the leader refused every later start
  with "a committed start is already served" until the provider was restarted.
- The leader now releases a start as soon as its session ends, and an
  unfinished serve of that start stands down without touching the next one.
  The release receipt still waits for the slot to retire. A pair still never
  serves two slots at once.
