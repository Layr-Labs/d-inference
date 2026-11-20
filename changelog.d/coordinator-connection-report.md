### Coordinator connection check in heartbeats

- Heartbeats report how the current coordinator connection compares with the
  build's coordinator host and certificate authorities
  (`coordinator_connection_check`), so the coordinator can count the results by
  provider version. Nothing is refused on it.
