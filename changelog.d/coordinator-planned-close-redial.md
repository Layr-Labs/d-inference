### Reconnect at once after a planned close

- `CoordinatorReconnectPolicy`: a close with code 1012 and the reason
  `planned move` waits nothing and does not grow the backoff. Only the
  coordinator's close pacer sends it: it closes the sockets of a planned event
  (an edge restart, a coordinator that stops, the move of a pair to its home)
  at a bounded rate, pair members first. A pair then serves again within the
  planned bar of 20 s.
- Every other close with code 1001 or 1012 keeps the 0 to 15 s spread, so a
  coordinator without the pacer keeps its protection from a reconnect storm.
- The receive callback reads the close reason from the frame's payload
  (`sentCloseReason`), as it reads the code, and the reconnect log line names it
  (`close_reason=`).
