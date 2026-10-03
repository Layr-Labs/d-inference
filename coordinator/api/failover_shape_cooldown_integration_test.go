package api

// P2 routing-failover integration tests (integrator pass).
//
// These exercise the shape-keyed inference-error breaker and capability
// fast-fail end-to-end against a real coordinator
// (httptest server, in-memory store, real registry) and the scripted
// fake-provider harness in failover_integration_test.go. They complement the
// registry-level unit tests in registry/error_cooldown_test.go and
// registry/scheduler_test.go by driving the full consumer dispatch path:
//
//   - TestShapeKeyedBreaker_ToolsTrippedBaseStillRoutes: a provider returns 500
//     to TWO tool requests (tripping the "tools" cooldown) but a plain
//     (no-tools) request to the SAME provider still routes and succeeds; and a
//     plain success does NOT lift the tools cooldown (the next tool request
//     avoids that provider). This is the exact prod-incident interleaving the
//     shape-keying closes.
//   - TestCooledToolsPair_ExcludedFromPreflight: after a (provider, model,
//     tools) cooldown is armed, a fresh tools request whose ONLY tools-capable
//     provider is the cooled one fast-fails (no 120s queue) — the shape-keyed
//     cooldown is consulted inside QuickCapacityCheck / the capability gate.
//
// INTEGRATION-NOTE: both depend on the registry shape-keyed breaker and the
// consumer dispatch wiring (PendingRequest.Traits from the parsed body and
// RecordInferenceError on terminals). They fail against either half alone.
//
// The speculative "both racers stall after the preamble feeds 504 into the
// breaker" arm (consumer.go ~2573) is NOT covered here: the both-missed arm
// only fires after the race deadline is extended by preambleContentTimeout
// (90s), which is impractical for a fast, non-flaky integration test. The
// 504-feeds-breaker contract on that arm is instead exercised at the unit
// level (registry/error_cooldown_test.go counts 504 as a strike) and shares
// the same noteInferenceError(504) call as the single-provider accepted-timeout
// path; see the integrator report.

// ---------------------------------------------------------------------------
// Test: shape-keyed breaker — tools cooldown does not deroute base traffic,
// and a base success does not lift the tools cooldown.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Test: a cooled (provider, model, tools) pair is excluded from the preflight,
// so a fresh tools request whose only capable provider is cooled fast-fails
// instead of queueing to timeout.
// ---------------------------------------------------------------------------
