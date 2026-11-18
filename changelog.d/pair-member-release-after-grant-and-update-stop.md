### Cluster pair members recover from a lost release receipt and release on an app update

- A pair member no longer refuses every new connection and prepare until it
  restarts when a session ended without its release receipt. Once the
  session's grant plus the 3-second native cleanup has passed on the Mac's
  uptime clock, and its owner process is gone, the member frees the session
  and accepts the next pair. A session whose owner still runs is still refused.
- A member that stops, for an app update or any other stop, now ends its pair
  session before it retires the pair slot, the same way a coordinator's cancel
  ends it. The leader's owner is no longer shut down outside its session, which
  made the session send a cancel and no receipt, so the coordinator held the
  pair's devices until the last grant plus 40 seconds. The stop now waits at
  most 30 seconds for the release receipt before it closes the connection.
- The member log now says at each stop whether the release receipt was sent.
