package registry

import (
	"sync"
	"sync/atomic"
	"time"
)

// gate_state.go — per-identity routing-gate state.
//
// Every fault tracker that gates routing — the node-health breaker
// (provider_breaker.go), stable-identity health ejection (health_ejection.go),
// the shape-keyed inference-error cooldown (error_cooldown.go), the capacity
// cooldown / rate window / budget clamp (capacity_cooldown.go, capacity_rate.go,
// budget_clamp.go) and the dispatch-load cooldown (model_loading.go) — used to live
// in global maps guarded by Registry.mu. Recording an outcome therefore took
// the registry WRITE lock: six times per served request, each acquisition
// draining the whole batch of fleet-scan readers first (~190 ms in prod). The
// holders were microseconds; the wait was structural.
//
// The state now lives in one gateState per fault key with its own mutex.
// Recorders resolve the gate, take gate.mu, mutate, release — they never touch
// r.mu. The scan reads the two hot booleans (breaker open, ejected) from
// atomics and takes gate.mu only for providers that actually carry per-model
// state (a flag word says which), so the common per-provider cost is a few
// atomic loads.
//
// LOCK ORDER: r.mu → p.mu → r.gatesMu → gate.mu. Never acquire r.mu or p.mu
// while holding gatesMu or a gate.mu. Recorders normally take gatesMu for
// READING (session → gate resolution); first insertion and the rare exhausted
// retry in lockGateWithIndex take it for writing. Register, Disconnect, the
// attestation-time identity bind (under the session's p.mu) and the periodic
// sweep also write the index. Only the identity
// migration (migrateGateLocked, under gatesMu.Lock) ever holds two gate.mu at
// once, so there is no ordering problem between gates. There is deliberately
// NO walk-wide gates lock on the scan: a lock taken for the whole fleet walk
// with per-completion writers would rebuild the exact convoy this removes.
//
// A recorder resolves its gate under gatesMu.RLock and locks it AFTER letting
// go of gatesMu, so the index can change in between: the identity bind can
// move the session to another gate, the sweep can drop the gate. The
// map-keyed implementation had no such window (key resolution and the write
// shared one r.mu.Lock section), so lockGate re-establishes it: after
// acquiring gate.mu it checks that the gate is still the one the outcome
// belongs to (not retired, still the session's cached gate) and otherwise
// releases, re-resolves through the index and retries. Everything that can
// invalidate a resolved gate — the forward, the retire flag, the session's
// repoint — is therefore written while holding that gate's mu. The routing
// READS are covered two ways. A rebind runs under the session's p.mu
// (bindStableFaultKey's callers hold it), so a read made under p.mu — the
// scan's gate chain, the reservation commit from its admit re-check through
// the pending debit, the alias resolver's routability read — never sees
// p.gate move mid-section. Independently of that lock, every read that feeds
// a dispatch decision confirms its verdict against p.gate afterwards and
// re-reads from the session's new gate when it moved (gateView,
// gate_index.go); that is what covers the candidate cost read the scan makes
// after it has released p.mu.
//
// Sections under gate.mu must stay per identity and microseconds long.
//
// The implementation is split by concern:
//
//	gate_state.go       — this header, the gateState struct, its lock-free view
//	                      (publishLocked and the atomic readers)
//	gate_index.go       — the registry-side index (r.gates / r.sessions under
//	                      gatesMu), session → gate resolution, attach/detach
//	gate_migrate.go     — identity binds and the state migration (forwards,
//	                      merge and reset policy)
//	gate_sweep.go       — the per-gate prune and the periodic index sweep
//	gate_lock.go        — the recorders' validated lock (lockGate), the
//	                      lock-free flag fast path and the wait observer
//	gate_commit_mode.go — the EIGENINFERENCE_RESERVE_COMMIT_MODE kill switch

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

	// Node-health breaker (provider_breaker.go).
	outcomes     *providerHealthWindow // nil until the first recorded fault/success
	breakerUntil time.Time
	breakerTrips int

	// Stable-identity health ejection (health_ejection.go).
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
	dispatchLoadCooldowns map[string]time.Time              // model_loading.go
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
