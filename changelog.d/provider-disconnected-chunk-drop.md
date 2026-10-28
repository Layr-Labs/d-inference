### Drop disconnected response chunks before reconnect

- Drop response frames processed by the chunk queue while no connection is
  bound, so their deferred flush cannot deliver them to a replacement session.
