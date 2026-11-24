### The heartbeat says how old the published decode rate is

Each slot's heartbeat now carries `observed_decode_tps_age_ms` beside
`observed_decode_tps`: the milliseconds since the newest sample that moved the
published rate (a reply of at least 32 tokens, or a calibration cell). Short
replies don't reset it. It is sent only with a published rate. The rate itself
and every provider decision are unchanged; the coordinator can use the age to
decay a stale rate toward the fleet median once it reads the field.
