package cold

import (
	"log/slog"

	retry "github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

type Policy struct {
	registry *registry.Registry
	logger   *slog.Logger
}

func New(reg *registry.Registry, logger *slog.Logger) *Policy {
	return &Policy{registry: reg, logger: logger}
}

const (
	EnvQueueBeforeShed = "EIGENINFERENCE_QUEUE_BEFORE_SHED"
	EnvColdDispatch    = "EIGENINFERENCE_COLD_DISPATCH"
)

// QueueBeforeShedEnabled reports whether capacity-rejected preflight requests
// are queued instead of immediately 429'd. Default true.
func (s *Policy) QueueBeforeShedEnabled() bool {
	return retry.EnvEnabledDefaultTrue(EnvQueueBeforeShed)
}

// Enabled reports whether the coordinator spills "no eligible
// provider" requests into the queue when an idle on-disk provider could be
// warmed, and proactively triggers cold loads for queued demand. Default true.
func (s *Policy) Enabled() bool {
	return retry.EnvEnabledDefaultTrue(EnvColdDispatch)
}

// SpillAvailable reports whether at least one idle on-disk provider could be
// warmed to serve `model` for a public request with these traits. Used by the
// preflight to turn an otherwise-immediate 503 `no_provider` into a queued
// cold-dispatch when warming can actually help.
func (s *Policy) SpillAvailable(model string, traits registry.RequestTraits, requiresVision bool, allowedSerials []string) bool {
	if s == nil || s.registry == nil {
		return false
	}
	return s.registry.ColdSpillProviders(model, traits, requiresVision, allowedSerials...) > 0
}

// Kick proactively triggers the model-swap machinery so a cold
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
func (s *Policy) Kick(model string) {
	if s == nil || s.registry == nil || model == "" {
		return
	}
	if !s.Enabled() {
		return
	}
	saferun.Go(s.logger, "api.coldDispatchSwap", func() {
		s.registry.TriggerModelSwaps()
	})
}
