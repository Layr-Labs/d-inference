### Two-Mac pairs recover after losing a rank during a stop

- A two-Mac pair no longer stays unable to serve when it loses a rank while
  its slot is stopping. Until the provider restarted, its leader refused every
  later start, and `darkbloom cluster stop` left that Mac's part still
  releasing.
- Fixed a deadlock in the pair's request engine. Stopping the pair slot
  cancelled a request's stream while the engine was telling that request the
  pair had lost a rank. The stream's cancellation waited for the engine, and the
  engine waited for the cancellation to finish, so the slot never stopped.
  Cancellation and stream termination now never wait for the engine.
- The leader also releases a committed start as soon as its session ends,
  instead of after the old slot has fully stopped, so a slow stop can no longer
  make it refuse later starts with "a committed start is already served". The
  release receipt still waits, bounded, for the slot to retire, and a pair still
  never serves two slots at once.
