### Idle Macs stop advertising a stale decode rate

An idle slot no longer publishes a decode rate measured more than 30 minutes
ago. The rate is a per-request EWMA measured at whatever batch the slot ran, and
it restarted only on a new sample, so a Mac that went idle after serving
several requests at once kept advertising its stacked rate. Routing ranked it
behind faster Macs and sent it nothing, so no new sample ever arrived. The
heartbeat now omits `observed_decode_tps` once nothing has run or waited on the
slot since its newest decode sample aged past the limit, and the coordinator
prices the Mac from its profile or the fleet, as it does after a reload.
`DARKBLOOM_DECODE_RATE_IDLE_MAX_AGE_SECONDS` sets the limit in seconds; `0`
restores 0.10.17's behaviour. The LaunchAgent forwards it.
