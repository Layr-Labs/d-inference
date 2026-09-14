package dispatch

import (
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

const (
	envQueueBeforeShed = "EIGENINFERENCE_QUEUE_BEFORE_SHED"
	envColdDispatch    = "EIGENINFERENCE_COLD_DISPATCH"
)

// envEnabledDefaultTrue parses a boolean env var that defaults to TRUE when
// unset. Only an explicit falsey value ("0"/"false"/"no"/"off",
// case-insensitive) disables the flag; anything else (including malformed input)
// leaves the default-safe behaviour enabled.
func envEnabledDefaultTrue(name string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(name))) {
	case "0", "false", "no", "off":
		return false
	default:
		return true
	}
}

// queueBeforeShedEnabled reports whether capacity-rejected preflight requests
// are queued instead of immediately 429'd. Default true.
func (s *Controller) QueueBeforeShedEnabled() bool {
	return envEnabledDefaultTrue(envQueueBeforeShed)
}

// coldDispatchEnabled reports whether the coordinator spills "no eligible
// provider" requests into the queue when an idle on-disk provider could be
// warmed, and proactively triggers cold loads for queued demand. Default true.
func (s *Controller) ColdDispatchEnabled() bool {
	return envEnabledDefaultTrue(envColdDispatch)
}

// coldSpillAvailable reports whether at least one idle on-disk provider could be
// warmed to serve `model` for a public request with these traits. Used by the
// preflight to turn an otherwise-immediate 503 `no_provider` into a queued
// cold-dispatch when warming can actually help.
func (s *Controller) ColdSpillAvailable(model string, traits registry.RequestTraits, requiresVision bool, allowedSerials []string) bool {
	if s == nil || s.deps.Registry() == nil {
		return false
	}
	return s.deps.Registry().ColdSpillProviders(model, traits, requiresVision, allowedSerials...) > 0
}

// kickColdDispatch proactively triggers the model-swap machinery so a cold
// provider is warmed for a freshly-queued model without waiting for the next
// heartbeat. It is a no-op when cold-dispatch is disabled. Safe to call on every
// enqueue: TriggerModelSwaps only loads models that have queued demand and no
// warm provider, and de-dups in-flight loads.
//
// It deliberately does NOT emit RecordWarmPoolColdDispatch: the queued request is
// already counted via the warm-pool queue-depth signal, and the cold-dispatch
// counter is recorded once at the actual cold reserve (registry/scheduler.go), so
// emitting here too would double-count the autoscaler's demand signal.
//
// The swap is dispatched on a recovered goroutine so the request hot path never
// blocks on registry locking.
func (s *Controller) kickColdDispatch(model string) {
	if s == nil || s.deps.Registry() == nil || model == "" {
		return
	}
	if !s.ColdDispatchEnabled() {
		return
	}
	saferun.Go(s.deps.Logger(), "api.coldDispatchSwap", func() {
		s.deps.Registry().TriggerModelSwaps()
	})
}
