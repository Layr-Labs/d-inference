package api

// E5: providers map a forced-tool_choice violation ("model did not emit the
// required tool call" / "outside tool_choice" / "deferred content limit") to a
// typed 422 with error_reason "tool_noncompliance". The coordinator must
// accept the reason into durable telemetry (whitelist) and keep the 422 on the
// normal bounded-failover path — a re-sample can comply.
