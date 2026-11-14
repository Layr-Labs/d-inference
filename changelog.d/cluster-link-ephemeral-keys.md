### Cluster link: fresh keys for every connection

- The link between the two Macs of a cluster pair now uses fresh keys for every connection, from an X25519 key agreement made in memory on both Macs and authenticated with the pairing's key. This covers everything the link carries (worker commands including prompts, outputs, bootstrap rounds, leases, status), for `darkbloom cluster local` / `start --local --distributed` and coordinator-formed pairs. Every reconnect makes new keys.
- The link handshake is now version 3, with no fallback: a Mac still on an older release cannot join its pair until both Macs run this release (the pair's update cycle updates both); the refusal reads `protocolVersionMismatch`.
