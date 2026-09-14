package faultstate

import (
	"sync"
	"sync/atomic"
	"time"
)

// Bits of gateState.pairFlags: which per-model trackers hold ANY entry for this
// identity. Published under gate.mu after every mutation; read lock-free by the
// scan so a provider with no per-model state costs no lock section at all.
const (
	gateFlagDispatchLoad uint32 = 1 << iota
	gateFlagErrorCooldown
	gateFlagCapacityCooldown
	gateFlagBudgetClamp
)

// modelShapeKey identifies an inference-error bucket inside one gate:
// (model, request shape). Shape is RequestTraits.CooldownShape ("tools" /
// "base"); see error_cooldown.go.
type modelShapeKey struct {
	Model string
	Shape string
}

// gateState is the fault state of ONE identity (fault key: serial → SE key →
// account → session id). Fields below the atomics are guarded by mu.
type gateState struct {
	// key is the fault key this state is filed under (immutable).
	key string
	mu  sync.Mutex

	// forwardTo is set when this gate has been migrated into another (identity
	// rebind) and is no longer in r.gates. Holders of a stale pointer follow it
	// (resolve / lockResolved) so a recorder that resolved the gate just before
	// the bind lands its outcome on the live state, not on the orphan.
	forwardTo atomic.Pointer[gateState]

	// live counts connected sessions bound to this gate. Guarded by r.gatesMu
	// (Register / Disconnect / bind / sweep). A gate with live > 0 is never
	// swept — deleting it would let the next lookup create a twin.
	live int

	// Lock-free routing view, published under mu after every mutation.
	breakerOpenUntilNS atomic.Int64  // 0 when the breaker has never opened
	ejectionUntilNS    atomic.Int64  // 0 when the identity has never been ejected
	pairFlags          atomic.Uint32 // gateFlag* bits: which per-model maps are non-empty
	newestRateRejectNS atomic.Int64  // newest capacity-503 rate reject across models; 0 = none

	// retired is set (under mu, before the index delete) when the sweep drops
	// this idle gate from r.gates. A recorder that resolved the gate before
	// the sweep and locks it afterwards must not write here — no lookup will
	// ever find this gate again — so lockGate re-resolves instead.
	retired bool

	// touched is when a recorder last mutated this gate, or when it was
	// created (sweep grace anchor: a fresh gate is not idle-droppable before
	// the first recorder that resolved it has had a chance to lock it).
	touched time.Time

	// Node-health breaker (breaker.go).
	outcomes     *providerHealthWindow // nil until the first recorded fault/success
	breakerUntil time.Time
	breakerTrips int

	// Stable-identity health ejection (ejection.go).
	ejection                 *providerHealthWindow
	ejectionUntil            time.Time
	ejectionTrips            int
	ejectionCapacityStreak   capacityStreak
	ejectionLastTripCapacity bool

	// Inference-error breaker, per (model, shape) (error_cooldown.go).
	inferenceErrorStrikes      map[modelShapeKey][]time.Time
	inferenceErrorCooldowns    map[modelShapeKey]time.Time
	inferenceErrorFlushStrikes map[modelShapeKey][]time.Time
	identityVersion            string
	versionResetAt             time.Time

	// Per-model trackers, keyed by model id.
	dispatchLoadCooldowns map[string]time.Time              // dispatch_load_cooldown.go
	capacityRejectStrikes map[string][]time.Time            // capacity_cooldown.go
	capacityCooldowns     map[string]*capacityCooldownEntry // capacity_cooldown.go
	capacityCooldownTrips map[string]int                    // capacity_cooldown.go
	budgetClamps          map[string]*budgetClampEntry      // budget_clamp.go
	capacityRateRejects   map[string][]time.Time            // capacity_rate.go
	capacityRateAccepts   map[string][]time.Time            // capacity_rate.go
}

func newGateState(key string) *gateState {
	return &gateState{
		key:                     key,
		inferenceErrorStrikes:   make(map[modelShapeKey][]time.Time),
		inferenceErrorCooldowns: make(map[modelShapeKey]time.Time),
		dispatchLoadCooldowns:   make(map[string]time.Time),
		capacityRejectStrikes:   make(map[string][]time.Time),
		capacityCooldowns:       make(map[string]*capacityCooldownEntry),
		capacityCooldownTrips:   make(map[string]int),
		budgetClamps:            make(map[string]*budgetClampEntry),
		capacityRateRejects:     make(map[string][]time.Time),
		capacityRateAccepts:     make(map[string][]time.Time),
	}
}

// publishLocked refreshes the lock-free routing view from the guarded state.
// Call after every mutation, before releasing mu.
func (g *gateState) publishLocked() {
	g.breakerOpenUntilNS.Store(unixNanoOrZero(g.breakerUntil))
	g.ejectionUntilNS.Store(unixNanoOrZero(g.ejectionUntil))
	var flags uint32
	if len(g.dispatchLoadCooldowns) > 0 {
		flags |= gateFlagDispatchLoad
	}
	if len(g.inferenceErrorCooldowns) > 0 {
		flags |= gateFlagErrorCooldown
	}
	if len(g.capacityCooldowns) > 0 {
		flags |= gateFlagCapacityCooldown
	}
	if len(g.budgetClamps) > 0 {
		flags |= gateFlagBudgetClamp
	}
	g.pairFlags.Store(flags)
	var newest int64
	for _, rejects := range g.capacityRateRejects {
		if n := len(rejects); n > 0 {
			if ns := rejects[n-1].UnixNano(); ns > newest {
				newest = ns
			}
		}
	}
	g.newestRateRejectNS.Store(newest)
}

// updatedLocked stamps the mutation time and publishes. Recorders call this at
// the end of every mutating section.
func (g *gateState) updatedLocked(now time.Time) {
	g.touched = now
	g.publishLocked()
}

func unixNanoOrZero(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixNano()
}

// breakerOpenAt reports whether the node-health breaker is open at nowNS.
// Lock-free; nil-safe (no gate = no state).
func (g *gateState) breakerOpenAt(nowNS int64) bool {
	return g != nil && nowNS < g.breakerOpenUntilNS.Load()
}

// ejectedAt reports whether the identity is health-ejected at nowNS.
// Lock-free; nil-safe.
func (g *gateState) ejectedAt(nowNS int64) bool {
	return g != nil && nowNS < g.ejectionUntilNS.Load()
}

// hasPairState reports (lock-free) whether any of the flagged per-model
// trackers holds an entry. Readers use it to skip the lock section entirely.
func (g *gateState) hasPairState(flag uint32) bool {
	return g != nil && g.pairFlags.Load()&flag != 0
}
