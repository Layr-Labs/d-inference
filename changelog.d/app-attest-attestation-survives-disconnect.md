### App Attest keeps an attestation cut off by a disconnect or a stop

- A Mac restarted during its Apple verification no longer loses private serving for an hour; a pair it leads starts serving once both Macs are verified.
- When the coordinator connection ends, or the provider is stopped (`darkbloom stop`, SIGTERM, the cluster service restarting this Mac's part, an update restart), while Apple is attesting a new App Attest key, the provider now lets Apple answer, waiting at most 30 seconds, and keeps the proof. The next connection sends that proof instead of retiring the key and waiting an hour for a replacement.
- A crash or forced kill during that Apple call still retires the key under the same one-hour rule, and the hourly key budget is unchanged.
