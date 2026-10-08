### Autopilot consent journal contention

- Let independent provider sessions record Autopilot consent concurrently instead of serializing the fleet behind the inventory write lock. Preserve per-session ownership, account-erasure fences, and exclusive protection for identity merges and reward settlement.
- Keep canonical-machine ownership lookups scoped to materialized ancestor IDs so PostgreSQL does not scan the complete provider-session history on each consent observation.
