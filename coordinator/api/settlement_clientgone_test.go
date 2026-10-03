package api

// Regression tests for the "client gone after commit, provider completed"
// outcome.
//
// When a consumer disconnects AFTER the response committed (first token sent)
// and the provider then COMPLETES, the request is settled from the parked
// billing record: the provider IS paid, the consumer IS charged, and it is NOT
// counted as a provider failure. The route outcome is partial_success with
// error_class client_gone_after_commit_provider_completed.
//
// These tests pin that composed invariant end-to-end through handleComplete (the
// component tests in settlement_test.go and route_outcome_test.go exercise the
// pieces, but not the full money + reputation + outcome path together). They also
// pin the exactly-once boundary from the other direction: once the settlement
// grace has refunded, a late provider terminal is a no-op (no double pay/charge).
