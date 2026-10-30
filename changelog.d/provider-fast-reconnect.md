### Faster coordinator reconnect

- A coordinator session that stayed open for 60 seconds or more resets the reconnect backoff. When such a session drops, the provider connects again after the shortest wait (0.5 to 1 second), not after a wait of up to 30 seconds that earlier drops grew.
- When the coordinator side closes the socket with WebSocket code 1012 (service restart), the provider connects again after a random wait of 0 to 1 second. This close does not grow the backoff.
- Other close codes, closes without a code and failed attempts keep the exponential backoff. Registration, attestation and the cancellation of the old connection's requests do not change.
