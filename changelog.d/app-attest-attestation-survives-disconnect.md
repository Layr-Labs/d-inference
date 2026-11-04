### App Attest keeps an attestation cut off by a disconnect or a stop

- When the coordinator connection ends, or the provider is stopped or restarted (`darkbloom stop`, the cluster service restarting this Mac's part, an update), while Apple is attesting a new App Attest key, the provider now waits up to 30 seconds for Apple's answer and keeps the proof. The next connection sends it instead of retiring the key, so the Mac no longer loses private serving for an hour, and a pair it leads can serve once both Macs are verified.
- A crash or forced kill during that Apple call still retires the key under the same one-hour rule, and the hourly key budget is unchanged.
