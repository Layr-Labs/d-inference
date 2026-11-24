### An idle Mac keeps its decode rate when the coordinator decays stale rates

The coordinator can now say, in `trust_status.coordinator_features`, that it
decays a stale `observed_decode_tps` by its `observed_decode_tps_age_ms`
(`decode_rate_age_decay`). While the connected coordinator says so, an idle
slot keeps publishing its decode rate and its age after
`DARKBLOOM_DECODE_RATE_IDLE_MAX_AGE_SECONDS`, instead of omitting it; the
coordinator moves an old rate toward the fleet median, so the slot keeps its
rank instead of alternating between no rate and an old one. Without the field
(every coordinator before it), with any other list, and after a disconnect, the
heartbeat is unchanged.
