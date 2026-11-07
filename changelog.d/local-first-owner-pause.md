### Me first: Darkbloom pauses while you use your Mac

- The provider can pause Darkbloom requests while you use this Mac through its local API, and take them again once
  none of your requests has run for the idle time (`[local] me_first_idle_minutes`, 2 minutes by default).
- While paused the Mac stays connected, keeps its models loaded and keeps its uptime. Darkbloom requests already
  running finish, and new ones go to other Macs. Heartbeats say `draining` with `busy_reason: "owner"`, which
  coordinators treat as a plain drain.
- It is event-driven: a heartbeat only when the pause begins or ends, one timer only while your idle time counts down,
  and nothing at all when it is off.
