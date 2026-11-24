### A short reply no longer sets a Mac's published decode rate

Only a request that generated at least 32 tokens now updates the decode rate a
slot publishes (`observed_decode_tps`), its age and the deadline decode rate,
matching the coordinator's own `completion_tokens >= 32` convention. A shorter
request's rate is mostly its first steps or its tail: one short reply could
pull a Mac that measured 80–100 tok/s down to about 11, and routing then ranked
it behind slower Macs. Shorter requests still count in their prompt-size bucket
and in generated work. A slot that has served only short requests publishes no
decode rate, as after a reload, and the coordinator prices it from its profile
or the fleet.
