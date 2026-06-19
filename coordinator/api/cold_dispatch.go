package api

import (
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Routing v2 — W3: cold-dispatch spill + queue-before-shed wiring.
//
// Both behaviours are default-ON and reversible without a rebuild via env flags.
// They are read here (not on the Server struct) so this workstream stays
// confined to its owned files — server.go / main.go are owned by parallel
// workstreams. The flags are read per call: a feature-flag lookup is negligible
// next to the JSON-parse + crypto + DB work each request already does, and
// reading live env keeps the flags overridable in tests (t.Setenv).
//
//   - EIGENINFERENCE_QUEUE_BEFORE_SHED (default true): when the preflight would
//     429 `machine_busy` (providers exist for the model but all are at capacity),
//     route the request into the normal dispatch+queue path instead, so a slot
//     freeing — or a cold load completing — within the queue window serves it.
//     The dispatch/queue path still returns a 429 when the queue is full or the
//     wait times out (true saturation).
//   - EIGENINFERENCE_COLD_DISPATCH (default true): (1) when the preflight would
//     503 `no_provider` but an idle on-disk provider could load the model, spill
//     the request into the queue instead of shedding; and (2) on every queue
//     enqueue, proactively kick the model-swap machinery so a cold provider is
//     warmed for the queued demand without waiting for the next heartbeat.

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
func (s *Server) queueBeforeShedEnabled() bool {
	return envEnabledDefaultTrue(envQueueBeforeShed)
}

// coldDispatchEnabled reports whether the coordinator spills "no eligible
// provider" requests into the queue when an idle on-disk provider could be
// warmed, and proactively triggers cold loads for queued demand. Default true.
func (s *Server) coldDispatchEnabled() bool {
	return envEnabledDefaultTrue(envColdDispatch)
}

// coldSpillAvailable reports whether at least one idle on-disk provider could be
// warmed to serve `model` for a public request with these traits. Used by the
// preflight to turn an otherwise-immediate 503 `no_provider` into a queued
// cold-dispatch when warming can actually help.
func (s *Server) coldSpillAvailable(model string, traits registry.RequestTraits, requiresVision bool, allowedSerials []string) bool {
	if s == nil || s.registry == nil {
		return false
	}
	return s.registry.ColdSpillProviders(model, traits, requiresVision, allowedSerials...) > 0
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
func (s *Server) kickColdDispatch(model string) {
	if s == nil || s.registry == nil || model == "" {
		return
	}
	if !s.coldDispatchEnabled() {
		return
	}
	saferun.Go(s.logger, "api.coldDispatchSwap", func() {
		s.registry.TriggerModelSwaps()
	})
}
