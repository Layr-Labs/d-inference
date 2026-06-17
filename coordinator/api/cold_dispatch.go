package api

import (
	"log/slog"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Routing v2 — W3: cold-dispatch spill + queue-before-shed wiring.
//
// Both behaviours are reversible without a rebuild via env flags, read per call:
// a feature-flag lookup is negligible next to the JSON-parse + crypto + DB work
// each request already does, and reading live env keeps the flags overridable in
// tests (t.Setenv).
//
//   - EIGENINFERENCE_QUEUE_BEFORE_SHED (default TRUE): when the preflight would
//     429 `machine_busy` (providers exist for the model but all are at capacity),
//     route the request into the normal dispatch+queue path instead, so a slot
//     freeing — or a cold load completing — within the queue window serves it.
//     The dispatch/queue path still returns a 429 when the queue is full or the
//     wait times out (true saturation).
//   - EIGENINFERENCE_COLD_DISPATCH (default FALSE, opt-in): (1) when the
//     preflight would 503 `no_provider` but an idle on-disk provider could load
//     the model, spill the request into the queue instead of shedding; and (2)
//     on every queue enqueue, proactively (and debounced) kick the model-swap
//     machinery so a cold provider is warmed for the queued demand without
//     waiting for the next heartbeat. Default-off because this path drove the
//     routing-v2 meltdown (registry write-lock storm + OOM cold loads); enable
//     only after the safety fixes (kick debounce + real-free admission) are
//     validated in the target environment.

const (
	envQueueBeforeShed         = "EIGENINFERENCE_QUEUE_BEFORE_SHED"
	envColdDispatch            = "EIGENINFERENCE_COLD_DISPATCH"
	envColdDispatchMinInterval = "EIGENINFERENCE_COLD_DISPATCH_MIN_INTERVAL"
)

// defaultColdDispatchMinInterval bounds how often kickColdDispatch may run
// TriggerModelSwaps. It collapses the per-enqueue kick (one per queued request)
// into at most one model-swap pass per interval, which is what stops the
// registry write-lock storm that took TriggerModelSwaps from O(1)/tick to
// O(request volume) write-lock acquisitions.
const defaultColdDispatchMinInterval = time.Second

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

// envEnabledDefaultFalse parses a boolean env var that defaults to FALSE when
// unset. Only an explicit truthy value ("1"/"true"/"yes"/"on",
// case-insensitive) enables the flag; anything else (including malformed input)
// leaves the default-safe behaviour disabled. Used for opt-in features that are
// risky on by default (e.g. cold-dispatch, which drove the routing-v2 meltdown).
func envEnabledDefaultFalse(name string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(name))) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

// queueBeforeShedEnabled reports whether capacity-rejected preflight requests
// are queued instead of immediately 429'd. Default true.
func (s *Server) queueBeforeShedEnabled() bool {
	return envEnabledDefaultTrue(envQueueBeforeShed)
}

// coldDispatchEnabled reports whether the coordinator spills "no eligible
// provider" requests into the queue when an idle on-disk provider could be
// warmed, and proactively triggers cold loads for queued demand. Default FALSE
// (opt-in): cold-dispatch was the routing-v2 meltdown trigger (write-lock storm
// + OOM cold loads), so it must be explicitly enabled via
// EIGENINFERENCE_COLD_DISPATCH=true after the safety fixes are validated.
func (s *Server) coldDispatchEnabled() bool {
	return envEnabledDefaultFalse(envColdDispatch)
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

// coldDispatchMinInterval returns the minimum interval between cold-dispatch
// model-swap passes. Configurable via EIGENINFERENCE_COLD_DISPATCH_MIN_INTERVAL
// (any Go duration, e.g. "500ms", "2s"); a missing, empty, malformed, or
// negative value falls back to defaultColdDispatchMinInterval.
func coldDispatchMinInterval() time.Duration {
	if v := strings.TrimSpace(os.Getenv(envColdDispatchMinInterval)); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d >= 0 {
			return d
		}
	}
	return defaultColdDispatchMinInterval
}

// coldKickState debounces cold-dispatch model-swap passes with a coalescing
// single-flight + min-interval gate, so TriggerModelSwaps runs at most once per
// interval no matter how many enqueues arrive. A burst of N enqueues collapses
// into a single swap pass instead of N registry write-lock acquisitions — this
// is the direct fix for the write-lock storm that caused the routing-v2
// meltdown. The zero value is ready to use.
type coldKickState struct {
	mu       sync.Mutex
	inFlight bool      // a swap pass is currently running
	last     time.Time // completion time of the most recent swap pass
}

// kick runs trigger() on a recovered goroutine at most once per minInterval,
// coalescing concurrent/rapid callers. It returns immediately (the swap never
// blocks the request hot path):
//   - if a pass is already in flight, drop (that pass covers this demand);
//   - if the previous pass finished less than minInterval ago, drop (the next
//     enqueue after the window, or a future heartbeat, covers it);
//   - otherwise mark in-flight and dispatch exactly one trigger(), then record
//     completion time and clear the in-flight flag.
func (k *coldKickState) kick(minInterval time.Duration, logger *slog.Logger, trigger func()) {
	now := time.Now()

	k.mu.Lock()
	if k.inFlight {
		k.mu.Unlock()
		return
	}
	if !k.last.IsZero() && now.Sub(k.last) < minInterval {
		k.mu.Unlock()
		return
	}
	k.inFlight = true
	k.mu.Unlock()

	saferun.Go(logger, "api.coldDispatchSwap", func() {
		defer func() {
			k.mu.Lock()
			k.inFlight = false
			k.last = time.Now()
			k.mu.Unlock()
		}()
		trigger()
	})
}

// kickColdDispatch proactively triggers the model-swap machinery so a cold
// provider is warmed for a freshly-queued model without waiting for the next
// heartbeat. It is a no-op when cold-dispatch is disabled.
//
// It is called on EVERY queue enqueue, so it is debounced through coldKickState:
// TriggerModelSwaps (which takes the registry WRITE lock) runs at most once per
// coldDispatchMinInterval, coalescing an arbitrarily large enqueue burst into a
// single swap pass. TriggerModelSwaps is itself idempotent — it only loads
// models with queued demand and no warm provider, and de-dups in-flight loads —
// so dropping redundant kicks loses nothing.
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
	s.coldKick.kick(coldDispatchMinInterval(), s.logger, func() {
		s.registry.TriggerModelSwaps()
	})
}
