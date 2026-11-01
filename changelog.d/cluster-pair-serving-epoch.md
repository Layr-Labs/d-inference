### Two-Mac pairs recover after a lost rank

- A two-Mac pair no longer stays unable to serve after it loses a rank, is
  fenced, or has a request cancelled before it started.
- Fixed a deadlock in the pair's request engine. Stopping the pair slot
  cancelled a request's stream while the engine was telling that request the
  pair had lost a rank. The stream's cancellation waited for the engine, and the
  engine waited for the cancellation to finish, so the slot never stopped.
  Cancellation and stream termination now never wait for the engine.
- The leader also releases a committed start as soon as its session ends,
  instead of after the old slot has fully stopped, so a slow stop can no longer
  make it refuse every later start with "a committed start is already served".
  The release receipt still waits for the slot to retire, and a pair still never
  serves two slots at once.
