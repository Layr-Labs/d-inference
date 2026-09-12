// Package registry tracks connected providers and routes inference requests.
//
// Routing applies model, trust, privacy, health, and capacity gates, then ranks
// candidates by estimated latency and load. Near-cost candidates spread requests
// by queue depth; verified prefix-cache evidence can resolve otherwise equal
// choices. Reservations revalidate provider state before committing capacity.
//
// Registry owns fleet-wide state and construction. Provider and PendingRequest
// own connection and request state; model inventory, loading, heartbeat ingestion,
// attestation policy, and read-only fleet views live in their respective modules.
// Provider disconnection and stale-heartbeat eviction clean up session state while
// bounded identity gates preserve applicable fault history across reconnects.
package registry

import (
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Registry holds all connected providers and provides routing.
type Registry struct {
	mu        sync.RWMutex
	providers map[string]*Provider

	queue *RequestQueue
	// drainSuppress rate-limits HEARTBEAT-triggered queue drains per model
	// after a saturated pass (queue_drain_suppress.go). Zero value ready.
	drainSuppress queueDrainSuppressor
	// drainPasses runs one queue-drain pass per model at a time and reruns it
	// for triggers that landed mid-pass (queue_drain_coalesce.go). Zero value
	// ready.
	drainPasses queueDrainCoalescer

	MinTrustLevel TrustLevel

	// dedicatedModels holds lowercased substring patterns identifying model
	// families that may ONLY route to providers dedicated to that family (a
	// provider whose entire advertised catalog matches the pattern). A request
	// whose resolved build id contains one of these patterns is restricted to
	// such dedicated boxes — for both routing candidate selection and the
	// capacity preflight that decides whether to shed (429) to OpenRouter. Empty
	// = feature disabled (default in tests and the e2e testbed, which never set
	// it). Configured once at startup from EIGENINFERENCE_DEDICATED_MODELS; see
	// SetDedicatedModels and dedicated_models.go. Guarded by r.mu.
	dedicatedModels []string

	// Quality-concurrency admission cap (see concurrency_cap.go). When enabled,
	// the per-provider concurrency cap for a model is tightened from the flat
	// fallback to quality_concurrency × overcommit, computed from the provider's
	// STATIC single-stream decode rate so slow/saturated models stop
	// over-admitting. Set once at startup via SetQualityConcurrencyCap; read on the
	// routing/preflight paths (which hold r.mu). qualityCapFloorTPS / qualityCapFallback
	// mirror the warm-pool DecodeFloorTPS / FallbackQualityConcurrency so admission
	// and warm-pool planning share the same quality math.
	qualityCapEnabled    bool
	qualityCapOvercommit float64
	qualityCapFloorTPS   float64
	qualityCapFallback   int

	// APNs code-identity rollout policy (v0.6.0), guarded by r.mu and evaluated
	// LIVE at every routing decision so a deadline can flip enforcement on/off
	// without forcing providers to reconnect.
	//
	//   - codeAttestationConfigured: true once an APNs attestor is wired
	//     (SetCodeAttestationConfigured). The coordinator only issues code-identity
	//     challenges when configured.
	//   - codeAttestationDeadline: the instant enforcement begins. Before it (or
	//     when zero) the coordinator is in GRACE/observe mode — it challenges and
	//     measures providers but still ROUTES un-attested ones, so configuring the
	//     attestor never deroutes the fleet. At/after the deadline, enforcement is
	//     fail-closed: un-attested providers (and any too-old to ever attest) stop
	//     being routed.
	//
	// Operator flow: set APNS_* secrets (configured, grace) → fleet updates to
	// 0.6.0 and attests → set APNS_ENFORCE_AFTER = release+24h → enforcement flips
	// on automatically when that instant passes.
	codeAttestationConfigured bool
	codeAttestationDeadline   time.Time

	// Active-release authorization is generation-bound. When at least one
	// release policy record exists, private routing requires application evidence
	// derived from the current generation; APNs identity alone is insufficient.
	releasePolicyGeneration uint64
	releasePolicyRequired   bool
	// releasePolicyEnforced gates whether missing/stale application evidence
	// actually blocks routing. false = SHADOW: evidence is still derived,
	// granted, swept, and counted (CountProvidersWithCurrentApplicationEvidence)
	// but a provider without it keeps routing exactly like the pre-release-policy
	// coordinator. true = ENFORCE: evidence is mandatory at the routing
	// chokepoint. A brand-new global trust gate MUST prove fleet compatibility
	// in shadow before it is allowed to deroute anything (2026-08-31 incident:
	// an unprovable evidence predicate zeroed network capacity twice).
	releasePolicyEnforced bool
	// releasePolicyEnforceAfter delays enforcement past process start: a
	// coordinator restarted with enforcement configured boots with an EMPTY
	// in-memory registry (zero evidence), so enforcing from the first request
	// would 429 every reconnecting provider until its first challenge —
	// recreating the exact transient the shadow rollout exists to prevent.
	// Zero means enforce immediately (tests, in-process flips).
	releasePolicyEnforceAfter time.Time

	modelCatalog map[string]CatalogEntry

	// modelAliases maps a public-facing alias id (e.g. "gemma-4-26b") to the
	// desired (and optional previous) concrete build it resolves to. Populated by
	// SetModelAliases at catalog sync time. nil = no aliases configured.
	modelAliases map[string]AliasTarget

	store store.Store

	tpsRegistry *TPSRegistry

	logger *slog.Logger
	// reservationAfterScan is a test-only barrier invoked with r.mu held for
	// shared reading after winner selection and before the serialized commit.
	// Production leaves it nil; tests set it before starting concurrent scans.
	reservationAfterScan func(model string)
	// drainBeforePop is a test-only barrier invoked with no locks held before
	// every pop of a queue-drain pass, so a test can interleave a trigger at a
	// chosen point of the pass. Production leaves it nil.
	drainBeforePop func(model string)

	// modelIndex maps advertised model id → providers advertising it, so the
	// per-request fleet walks visit only providers that can pass the first
	// gate (model_index.go). Leaf lock — see that file for the contract.
	modelIndex providerModelIndex
	// modelIndexDisabled (tests only) makes providersForModelLocked return the
	// whole fleet so a walk can be proven identical with and without the index.
	modelIndexDisabled bool

	// swapPlanGate coalesces heartbeat-triggered model-swap planning to at
	// most one plan per modelSwapPlanInterval fleet-wide (model_swap_coalesce.go).
	swapPlanGate modelSwapPlanGate

	onlineCount      atomic.Int64
	modelProviders   map[string]*atomic.Int64
	modelProvidersMu sync.Mutex

	// pendingModelLoads tracks provider-model pairs that have been sent a
	// load_model command and are awaiting completion, or are cooling down
	// after a failed one. The value is the entry's expiry time. While an
	// entry lives, the provider is skipped for new load_model sends
	// (bestModelLoadProviderLocked / reservePendingModelLoads).
	//
	// SCOPE: this map is consulted ONLY by warm-pool / model-swap PLANNING. It
	// does NOT participate in request routing or admission — the dispatch hot
	// path (snapshotProviderLockedEx, buildCandidateWithReason) and the capacity
	// preflight (QuickCapacityCheck) never read it. A pending load neither makes
	// a provider eligible nor reserves capacity for routing; routing eligibility
	// is derived entirely from BackendCapacity.Slots (with WarmModels as the
	// legacy fallback). Do not add routing reads of this field — see the
	// "Coordinator State Model" section in AGENTS.md.
	pendingModelLoads       map[modelLoadKey]time.Time // value: expiry (see pair_keys.go)
	pendingModelLoadStarted map[modelLoadKey]time.Time

	// Per-identity routing-gate state (gate_state.go). Every fault tracker —
	// the dispatch-load cooldown, the shape-keyed inference-error breaker
	// (error_cooldown.go), the node-health breaker (provider_breaker.go), the
	// capacity cooldown / rate window / budget clamp (capacity_cooldown.go,
	// capacity_rate.go, budget_clamp.go) and stable-identity health ejection
	// (health_ejection.go) — lives on the gateState of the provider's STABLE
	// fault key (serial → SE key → account → session id), each gate with its
	// own mutex. Recorders take gate.mu only, never r.mu: the six per-request
	// write acquisitions of r.mu that convoyed behind the fleet-scan readers
	// are gone. gates is keyed by fault key; sessions indexes LIVE session ids
	// to their Provider (whose p.gate caches the current gate) so recorders
	// resolve a session without r.mu; disconnectedStableIDs caches a
	// provider's stable identity at Disconnect time, keyed by its now-removed
	// session id, so the trailing pending-request ErrorCh flush — which
	// carries the 502 "provider disconnected" faults that define a
	// reconnecting zombie — still resolves the identity. All three under
	// gatesMu: RLock to resolve, Lock only in Register / Disconnect / the
	// attestation-time bind / the periodic sweep. Fault state is keyed by
	// identity and NOT cleared on Disconnect — it re-attaches on reconnect
	// (the prod zombie exploit: median 18 sessions/machine/week reset every
	// session-keyed breaker before it could trip).
	gatesMu               sync.RWMutex
	gates                 map[string]*gateState
	sessions              map[string]*Provider
	disconnectedStableIDs map[string]disconnectedStableID
	gateSweepAt           time.Time
	// gateWaitObserver, when set, is told about gate.mu acquisition waits above
	// gateWaitReportThreshold, tagged by recorder site (SetGateWaitObserver).
	gateWaitObserver atomic.Pointer[func(site string, wait time.Duration)]

	// reserveCommitMode selects whether the reservation commit holds r.mu for
	// reading (shared, default) or writing (global — the kill switch). Read
	// once from EIGENINFERENCE_RESERVE_COMMIT_MODE at construction.
	reserveCommitMode reserveCommitMode

	// Env-tunable tracker configs, read once at construction.
	capacityCooldownCfg capacityCooldownConfig
	budgetClampCfg      budgetClampConfig
	capacityRateCfg     capacityRateConfig

	// evictStrikes counts consecutive eviction sweeps a provider has been stale.
	// A provider is only evicted after STALE on two sweeps in a row, so a single
	// transient coordinator stall (which ages many LastHeartbeat values at once)
	// or one missed heartbeat doesn't mass-reap a live fleet. Guarded by r.mu;
	// rebuilt each sweep so disconnected providers drop out automatically.
	evictStrikes map[string]int

	// capacityQuotes correlates outstanding capacity probes with their quotes
	// by quote_id (routing v2 W2). Value field with an internal LEAF mutex and
	// a lazily-created map, so bare &Registry{} test constructions work
	// without New(). See capacity_quotes.go.
	capacityQuotes quoteTracker

	cacheRouting                 *cacheRoutingTracker
	cacheActivation              *cacheActivationGate
	cacheRoutingMode             string
	cacheRoutingAllowedArtifacts cacheArtifactAllowlist
	cacheRouteKeys               cacheRouteKeys
	cacheRoutingMaxDiscountMs    *float64
	cacheRoutingMaxCostFraction  *float64
	warmPool                     *warmPoolController
	// Provider-control sender seams let focused tests prove eligibility failures
	// stop before any command invocation. Nil uses the provider WebSocket.
	loadModelSender               func(providerID, modelID string) error
	prefetchModelSender           func(providerID, modelID string, priority int) error
	desiredModelsSender           func(providerID string, entries []protocol.DesiredModelEntry) error
	onRuntimeCapabilitiesPromoted func(providerID string)

	// onHardUntrust is an optional hook fired (off the registry locks) whenever a
	// provider is HARD-untrusted (a non-recoverable security deroute). The api
	// layer wires it to invalidate that device's trust-reuse record (DAR-326), so
	// "hard untrust always takes effect" stays durable across coordinator
	// restarts. Keyed by the device's Secure Enclave public key. Set once at
	// startup; nil = no-op. Guarded by r.mu (set + read).
	onHardUntrust func(seKey string)
	// lockWaitObserver, when set, is told how long each request-path write
	// acquisition of r.mu waited, tagged by call site (see lockWrite).
	lockWaitObserver atomic.Pointer[func(site string, wait time.Duration)]
}

// New creates a new Registry.
func New(logger *slog.Logger) *Registry {
	return &Registry{
		providers:               make(map[string]*Provider),
		queue:                   NewRequestQueueFromEnv(),
		MinTrustLevel:           TrustHardware,
		tpsRegistry:             NewTPSRegistry(),
		modelProviders:          make(map[string]*atomic.Int64),
		pendingModelLoads:       make(map[modelLoadKey]time.Time),
		pendingModelLoadStarted: make(map[modelLoadKey]time.Time),
		gates:                   make(map[string]*gateState),
		sessions:                make(map[string]*Provider),
		disconnectedStableIDs:   make(map[string]disconnectedStableID),
		reserveCommitMode:       loadReserveCommitMode(logger),
		capacityCooldownCfg:     loadCapacityCooldownConfig(),
		budgetClampCfg:          loadBudgetClampConfig(),
		capacityRateCfg:         loadCapacityRateConfig(),
		evictStrikes:            make(map[string]int),
		cacheRouting:            newCacheRoutingTracker(defaultCacheRoutingTTL, defaultCacheRoutingMaxHolders),
		cacheActivation:         newCacheActivationGate(defaultCacheRoutingActivationPct, defaultCacheRoutingMaxPlanQPS),
		cacheRoutingMode:        CacheRoutingOff,
		logger:                  logger,
	}
}

// Queue returns the registry's request queue. Reads under r.mu so it
// synchronizes with SetQueue (tests swap the queue while heartbeat/drain
// goroutines are live); internal paths that already hold r.mu read r.queue
// directly.
func (r *Registry) Queue() *RequestQueue {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.queue
}

// SetQueue replaces the registry's request queue. This is useful for tests
// that need a larger queue capacity than the default.
func (r *Registry) SetQueue(q *RequestQueue) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.queue = q
}

// GetProvider returns a provider by ID, or nil if not found.
func (r *Registry) GetProvider(id string) *Provider {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providers[id]
}

// HoldWriteLockForTest acquires the registry write lock and returns the
// function that releases it. Test-only, in the spirit of reservationAfterScan:
// it lets api-package tests prove that a request-path step no longer waits on
// r.mu (for example that the first client byte is written while a writer holds
// the lock). Production code never calls it.
func (r *Registry) HoldWriteLockForTest() (release func()) {
	r.mu.Lock()
	return r.mu.Unlock
}

// ForEachProvider iterates over all registered providers (read lock held).
func (r *Registry) ForEachProvider(fn func(p *Provider)) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		fn(p)
	}
}

// ProviderIDs returns the IDs of all registered providers.
func (r *Registry) ProviderIDs() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	ids := make([]string, 0, len(r.providers))
	for id := range r.providers {
		ids = append(ids, id)
	}
	return ids
}
