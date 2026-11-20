### A pair member reports itself as soon as the coordinator accepts it

- A cluster pair member now sends its first heartbeat on each connection as
  soon as the coordinator accepts its registration, instead of one heartbeat
  interval later. The coordinator routes requests to a pair only after each
  member's heartbeat reports its session, so a pair that reconnects (for
  example after a coordinator edge restart) can take requests again about one
  interval sooner. Later heartbeats keep the normal interval.
- A pair member whose heartbeat fails to encode now sends nothing instead of
  the minimal fallback heartbeat, which had no capacity sequence and no
  session report and so withdrew the member's session at the coordinator.
  Its next heartbeat reports the full state. Every heartbeat now leaves in
  capacity-sequence order.
