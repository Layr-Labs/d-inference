### Cluster link: fresh keys for every connection

- The link between the two Macs of a cluster pair now keys each connection from a fresh X25519 key agreement made in memory on both Macs, authenticated with the pairing's edge key, so the edge key stored on each Mac no longer decrypts link traffic on its own. This covers everything the link carries (worker commands including prompts, outputs, bootstrap rounds, leases, status), for `darkbloom cluster local` / `start --local --distributed` and coordinator-formed pairs. Every reconnect makes new keys.
- The link handshake is now version 2, with no fallback: a Mac still on an older release cannot join its pair until both Macs run this release (the pair's update cycle updates both); the refusal reads `protocolVersionMismatch`.
