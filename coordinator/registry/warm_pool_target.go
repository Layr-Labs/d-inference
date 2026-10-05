package registry

// warm_pool_target.go holds the pure, side-effect-free math behind the
// warm-pool controller's capacity target (Layer 3 in docs/design/routing-v2.md).
//
// The controller drives warm capacity from measured demand using Little's Law:
//
//	L = λ · E[S]                         (requests concurrently in the system)
//	target_warm = ceil( L / quality_concurrency ) + burst_buffer
//
// where quality_concurrency comes from each provider's exact reviewed profile,
// with the existing solo/(1+k*B) quality curve retained for unknown profiles.
// Measured prompt work / prefill capacity + output work / aggregate decode
// capacity supplies an independent floor without treating memory reservations
// as generation demand or dividing serial prompt work by decode batch width.
//
// Everything here is pure so it can be unit-tested without a Registry, heartbeats,
// or wall-clock timing.
