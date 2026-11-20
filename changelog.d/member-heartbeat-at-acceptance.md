### A pair member reports itself as soon as the coordinator accepts it

- A cluster pair member now sends its first heartbeat on each connection as
  soon as the coordinator accepts its registration, instead of one heartbeat
  interval later. The coordinator routes requests to a pair only after each
  member's heartbeat reports its session, so a pair that reconnects (for
  example after a coordinator edge restart) can take requests again about one
  interval sooner. Later heartbeats keep the normal interval.
