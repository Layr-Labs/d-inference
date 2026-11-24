### A short reply no longer moves a Mac's published decode rate

The decode rate a slot publishes (`observed_decode_tps`) now moves only on a
request that generated at least 32 tokens, matching the coordinator's own
`completion_tokens >= 32` convention. A shorter request's rate is mostly its
first steps or its tail: one short reply could pull a Mac that measured 80–100
tok/s down to about 11, and routing then ranked it behind slower Macs. Shorter
requests still feed the rate's age and `performance_measurements` exactly as
before, so the idle age is unchanged. A slot that has served only short replies
publishes no decode rate, as a slot with no samples does, and the coordinator
prices it from its profile or the fleet.
