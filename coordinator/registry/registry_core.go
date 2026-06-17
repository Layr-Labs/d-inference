package registry

import (
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Registry holds all connected providers and provides routing.
type Registry struct {
	mu        sync.RWMutex
	providers map[string]*Provider

	queue *RequestQueue

	MinTrustLevel TrustLevel

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

	modelCatalog map[string]CatalogEntry

	// modelAliases maps a public-facing alias id (e.g. "gemma-4-26b") to the
	// desired (and optional previous) concrete build it resolves to. Populated by
	// SetModelAliases at catalog sync time. nil = no aliases configured.
	modelAliases map[string]AliasTarget

	store store.Store

	tpsRegistry *TPSRegistry

	logger *slog.Logger

	onlineCount      atomic.Int64
	modelProviders   map[string]*atomic.Int64
	modelProvidersMu sync.Mutex

	// pendingModelLoads tracks provider-model pairs that have been sent a
	// load_model command and are awaiting completion, or are cooling down
	// after a failed one. The value is the entry's expiry time. While an
	// entry lives, the provider is skipped for new load_model sends
	// (bestModelLoadProviderLocked / reservePendingModelLoads).
	pendingModelLoads       map[string]time.Time // key: "providerID:modelID", value: expiry
	pendingModelLoadStarted map[string]time.Time // key: "providerID:modelID", value: send time
	loadModelSender         func(providerID, modelID string) error

	cacheAffinity        *cacheAffinityTracker
	cacheAffinityBonusMs float64
	warmPool             *warmPoolController

	// dispatchLoadCooldowns: provider-model pairs that rejected a dispatch with a
	// load failure ("insufficient memory"). Routing skips the pair until expiry —
	// it would instant-503 again, and without this the scheduler re-picks it
	// (looks idle), causing the dispatch→503→retry storms seen in prod. Cleared
	// on re-registration and on a served request for the pair.
	dispatchLoadCooldowns map[string]time.Time // key: "providerID:modelID", value: expiry

	// inferenceErrorStrikes / inferenceErrorCooldowns implement the error-class
	// circuit breaker for provider-side inference failures: a (provider, model,
	// shape) triple that returns repeated 5xx errors (e.g. the deterministic
	// Gemma chat-template render crash on tool schemas) enters a routing
	// cool-down so retries fall to OTHER providers instead of burning every
	// attempt on the same broken pair. 4xx (client-shape) errors never count.
	//
	// The key is SHAPE-KEYED (inferenceErrorKey) rather than a "providerID:modelID"
	// string concat. Shape-keying fixes the root bug where a clean non-tool
	// success reset the SHARED strike counter, so in mixed traffic a deterministic
	// tool/template failure interleaved with text successes never reached the
	// 2-strike threshold and the broken provider was never quarantined for tools.
	// Strikes now accumulate per shape ("tools" independent of "base"), a success
	// clears only its own shape bucket, and the struct key also closes the
	// threat-model colon-collision note (a provider or model id containing ':'
	// could previously alias another pair). Strikes slide over inferenceErrorWindow.
	// Guarded by r.mu like dispatchLoadCooldowns. See error_cooldown.go.
	inferenceErrorStrikes   map[inferenceErrorKey][]time.Time // recent 5xx strike times per (provider, model, shape)
	inferenceErrorCooldowns map[inferenceErrorKey]time.Time   // cool-down expiry per (provider, model, shape)

	// evictStrikes counts consecutive eviction sweeps a provider has been stale.
	// A provider is only evicted after STALE on two sweeps in a row, so a single
	// transient coordinator stall (which ages many LastHeartbeat values at once)
	// or one missed heartbeat doesn't mass-reap a live fleet. Guarded by r.mu;
	// rebuilt each sweep so disconnected providers drop out automatically.
	evictStrikes map[string]int
}

// pendingModelLoadTTL bounds how long an outstanding (or failed) load_model
// suppresses re-sends to the same provider.
const pendingModelLoadTTL = 2 * time.Minute

// pendingModelLoadDrainBackoff is the short cooldown used when a provider
// rejects load_model because it is draining for an auto-update restart. The
// entry keeps the planner away from a provider that is about to bounce, but
// must not outlive a failed restart: if the provider aborts the restart and
// resumes serving, it is fully loadable again, and the full 2-minute cooldown
// would strand queued requests that this provider (or its post-restart
// re-registration) could serve.
const pendingModelLoadDrainBackoff = 30 * time.Second

// dispatchLoadCooldownTTL is how long routing skips a pair after a dispatch
// load failure — long enough to stop the retry loop, short enough that a
// recovered provider returns on its own.
const dispatchLoadCooldownTTL = 2 * time.Minute

type modelLoadAction struct {
	providerID string
	modelID    string
}

// New creates a new Registry.
func New(logger *slog.Logger) *Registry {
	return &Registry{
		providers:               make(map[string]*Provider),
		queue:                   NewRequestQueue(10, 120*time.Second),
		MinTrustLevel:           TrustHardware,
		tpsRegistry:             NewTPSRegistry(),
		modelProviders:          make(map[string]*atomic.Int64),
		pendingModelLoads:       make(map[string]time.Time),
		pendingModelLoadStarted: make(map[string]time.Time),
		cacheAffinity:           newCacheAffinityTracker(cacheAffinityTTL),
		cacheAffinityBonusMs:    defaultCacheAffinityBonusMs,
		dispatchLoadCooldowns:   make(map[string]time.Time),
		inferenceErrorStrikes:   make(map[inferenceErrorKey][]time.Time),
		inferenceErrorCooldowns: make(map[inferenceErrorKey]time.Time),
		evictStrikes:            make(map[string]int),
		logger:                  logger,
	}
}

// RecordDispatchLoadFailure puts a provider-model pair on a routing cool-down
// after the provider rejected a dispatch with a load failure. Returns true
// when this call started a new cool-down (false when one was already live),
// so callers can emit metrics without double-counting the retry storm.
func (r *Registry) RecordDispatchLoadFailure(providerID, modelID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	// Opportunistic sweep: provider ids are per-session UUIDs, so dead entries
	// never get re-keyed — bound the map by dropping expired ones when it grows.
	if len(r.dispatchLoadCooldowns) > 1024 {
		for key, expiry := range r.dispatchLoadCooldowns {
			if !now.Before(expiry) {
				delete(r.dispatchLoadCooldowns, key)
			}
		}
	}
	key := providerID + ":" + modelID
	_, active := r.dispatchLoadCooldowns[key]
	active = active && now.Before(r.dispatchLoadCooldowns[key])
	r.dispatchLoadCooldowns[key] = now.Add(dispatchLoadCooldownTTL)
	return !active
}

// ClearDispatchLoadCooldown removes the cool-down for one provider-model pair
// (called when the pair serves a request successfully — it can load after all).
func (r *Registry) ClearDispatchLoadCooldown(providerID, modelID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.dispatchLoadCooldowns, providerID+":"+modelID)
}

// clearDispatchLoadCooldownsLocked drops a provider's cool-downs on
// (re-)registration — a fresh process has fresh memory. Caller holds r.mu.
func (r *Registry) clearDispatchLoadCooldownsLocked(providerID string) {
	prefix := providerID + ":"
	for key := range r.dispatchLoadCooldowns {
		if strings.HasPrefix(key, prefix) {
			delete(r.dispatchLoadCooldowns, key)
		}
	}
}

// dispatchLoadCooldownActiveLocked reports whether routing should skip the pair.
// READ-ONLY (no lazy delete) — some callers hold only r.mu.RLock. Caller holds
// r.mu in either mode.
func (r *Registry) dispatchLoadCooldownActiveLocked(providerID, modelID string, now time.Time) bool {
	expiry, ok := r.dispatchLoadCooldowns[providerID+":"+modelID]
	return ok && now.Before(expiry)
}

// SetStore configures the persistence store for the registry.
// When set, provider state and reputation are persisted to the store.
func (r *Registry) SetStore(st store.Store) {
	r.store = st
}

// LoadStoredProviders loads provider records and reputation from the store
// on startup. This pre-populates a lookup table so that reconnecting providers
// can have their trust level and reputation restored. Providers are NOT added
// to the active registry (they need to reconnect via WebSocket first).
func (r *Registry) LoadStoredProviders() map[string]*store.ProviderRecord {
	if r.store == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	records, err := r.store.ListProviderRecords(ctx)
	if err != nil {
		r.logger.Warn("failed to load stored providers", "error", err)
		return nil
	}

	lookup := make(map[string]*store.ProviderRecord, len(records))
	for i := range records {
		rec := records[i]
		// Index by serial number for matching reconnecting providers
		if rec.SerialNumber != "" {
			lookup[rec.SerialNumber] = &rec
		}
		// Also index by SE public key
		if rec.SEPublicKey != "" {
			lookup["sekey:"+rec.SEPublicKey] = &rec
		}
	}

	r.logger.Info("loaded stored provider records", "count", len(records))
	return lookup
}

// RestoreProviderState restores trust level and reputation from a stored record
// onto a live provider. Called after a provider reconnects and is matched to
// its stored state by serial number or SE key.
func (r *Registry) RestoreProviderState(p *Provider, rec *store.ProviderRecord) {
	if rec == nil {
		return
	}

	p.mu.Lock()
	defer p.mu.Unlock()

	// Restore trust level, but NEVER above self_signed. Hardware trust must be
	// re-earned via a fresh live challenge + MDM/ACME on every (re)connection.
	// Resurrecting a stored "hardware" level would route real traffic to a
	// provider that has not yet passed a live challenge, and is the source of
	// the "registry says hardware but the live verdict is self_signed" drift.
	// The challenge-success path (verifyChallengeResponse) re-upgrades to
	// hardware once the live legs pass.
	if r := trustRank(TrustLevel(rec.TrustLevel)); r > trustRank(TrustSelfSigned) {
		p.TrustLevel = TrustSelfSigned
	} else {
		p.TrustLevel = TrustLevel(rec.TrustLevel)
	}
	// Do NOT clobber a fresh live attestation: verifyProviderAttestation runs
	// just before this and may have already set Attested=true (self_signed) from
	// a passing SE attestation. Only fall back to the stored flag when we don't
	// already have a fresh one — otherwise consumers/stats would see
	// X-Provider-Attested:false despite a successful live attestation.
	if !p.Attested {
		p.Attested = rec.Attested
	}
	p.MDAVerified = false
	p.ACMEVerified = false

	// Restore challenge state, but never move a fresh live verification
	// backwards. Registration attestation sets LastChallengeVerified=now before
	// RestoreProviderState runs; clobbering it with an old persisted timestamp
	// can make a just-reconnected provider fail the freshness gate until the
	// first challenge response lands.
	if rec.LastChallengeVerified != nil && rec.LastChallengeVerified.After(p.LastChallengeVerified) {
		p.LastChallengeVerified = *rec.LastChallengeVerified
	}
	p.FailedChallenges = rec.FailedChallenges

	// Restore location only if the provider doesn't already have a fresh one
	// (attachProviderLocation may have set it from the current request before
	// RestoreProviderState runs).
	if rec.Location != nil && p.Location == nil {
		cp := *rec.Location
		p.Location = &cp
	}

	// Restore account linkage
	if rec.AccountID != "" && p.AccountID == "" {
		p.AccountID = rec.AccountID
	}

	// Restore lifetime counters and the last raw session counters so future
	// heartbeats can merge cleanly after coordinator or provider restarts.
	p.Stats = protocol.HeartbeatStats{
		RequestsServed:  rec.LifetimeRequestsServed,
		TokensGenerated: rec.LifetimeTokensGenerated,
	}
	p.lastSessionStats = protocol.HeartbeatStats{
		RequestsServed:  rec.LastSessionRequestsServed,
		TokensGenerated: rec.LastSessionTokensGenerated,
	}

	// Restore reputation from store
	if r.store != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		repRec, err := r.store.GetReputation(ctx, rec.ID)
		if err == nil {
			p.Reputation.TotalJobs = repRec.TotalJobs
			p.Reputation.SuccessfulJobs = repRec.SuccessfulJobs
			p.Reputation.FailedJobs = repRec.FailedJobs
			p.Reputation.TotalUptime = time.Duration(repRec.TotalUptimeSeconds) * time.Second
			p.Reputation.AvgResponseTime = time.Duration(repRec.AvgResponseTimeMs) * time.Millisecond
			p.Reputation.ChallengesPassed = repRec.ChallengesPassed
			p.Reputation.ChallengesFailed = repRec.ChallengesFailed
		}
	}

	r.logger.Info("restored provider state from store",
		"provider_id", p.ID,
		"stored_id", rec.ID,
		"trust_level", rec.TrustLevel,
		"attested", rec.Attested,
		"serial", rec.SerialNumber,
	)
}

// PersistProvider unconditionally persists provider state to the store.
// Use for critical state changes (attestation, trust level, disconnect).
func (r *Registry) PersistProvider(p *Provider) {
	r.persistProviderNow(p)
}

// PersistProviderThrottled persists provider state at most once per 30 seconds.
// Use for high-frequency updates (heartbeats) that would otherwise saturate the
// DB connection pool. Skipped writes are not lost — the next unthrottled persist
// or the next throttle window will capture the current state.
func (r *Registry) PersistProviderThrottled(p *Provider) {
	const minInterval = 30 * time.Second
	p.mu.Lock()
	if time.Since(p.lastPersisted) < minInterval {
		p.mu.Unlock()
		return
	}
	p.lastPersisted = time.Now()
	p.mu.Unlock()
	r.persistProviderNow(p)
}

func (r *Registry) persistReputationThrottled(p *Provider) {
	const minInterval = 30 * time.Second
	p.mu.Lock()
	if time.Since(p.lastReputationPersisted) < minInterval {
		p.mu.Unlock()
		return
	}
	p.lastReputationPersisted = time.Now()
	p.mu.Unlock()
	r.persistReputation(p)
}

// persistProviderNow saves a provider's current state to the store.
// Called asynchronously to avoid blocking the hot path.
func (r *Registry) persistProviderNow(p *Provider) {
	if r.store == nil {
		return
	}
	saferun.Go(r.logger, "registry.persistProvider", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		p.mu.Lock()
		hardwareJSON, _ := json.Marshal(p.Hardware)
		modelsJSON, _ := json.Marshal(p.Models)
		var attestJSON json.RawMessage
		if p.AttestationResult != nil {
			attestJSON, _ = json.Marshal(p.AttestationResult)
		}
		seKey := ""
		serial := ""
		if p.AttestationResult != nil {
			seKey = p.AttestationResult.PublicKey
			serial = p.AttestationResult.SerialNumber
		}
		var mdaCertJSON json.RawMessage
		if len(p.MDACertChain) > 0 {
			mdaCertJSON, _ = json.Marshal(p.MDACertChain)
		}
		var lastChallenge *time.Time
		if !p.LastChallengeVerified.IsZero() {
			t := p.LastChallengeVerified
			lastChallenge = &t
		}

		var locationCopy *store.ProviderLocation
		if p.Location != nil {
			lc := *p.Location
			locationCopy = &lc
		}

		rec := store.ProviderRecord{
			ID:                         p.ID,
			Hardware:                   hardwareJSON,
			Models:                     modelsJSON,
			Backend:                    p.Backend,
			Location:                   locationCopy,
			TrustLevel:                 string(p.TrustLevel),
			Attested:                   p.Attested,
			AttestationResult:          attestJSON,
			SEPublicKey:                seKey,
			PublicKey:                  p.PublicKey,
			SerialNumber:               serial,
			MDAVerified:                p.MDAVerified,
			MDACertChain:               mdaCertJSON,
			ACMEVerified:               p.ACMEVerified,
			Version:                    p.Version,
			RuntimeVerified:            p.RuntimeVerified,
			PythonHash:                 p.PythonHash,
			RuntimeHash:                p.RuntimeHash,
			LastChallengeVerified:      lastChallenge,
			FailedChallenges:           p.FailedChallenges,
			AccountID:                  p.AccountID,
			LifetimeRequestsServed:     p.Stats.RequestsServed,
			LifetimeTokensGenerated:    p.Stats.TokensGenerated,
			LastSessionRequestsServed:  p.lastSessionStats.RequestsServed,
			LastSessionTokensGenerated: p.lastSessionStats.TokensGenerated,
			RegisteredAt:               time.Now(),
			LastSeen:                   time.Now(),
		}
		p.mu.Unlock()

		if err := r.store.UpsertProvider(ctx, rec); err != nil {
			r.logger.Warn("failed to persist provider", "provider_id", p.ID, "error", err)
		}

		// Keep this connection's session row fresh and backfill serial/account
		// once attestation/linking has populated them.
		if err := r.store.TouchProviderSession(ctx, rec.ID, rec.SerialNumber, rec.AccountID, rec.LastSeen); err != nil {
			r.logger.Warn("failed to touch provider session", "provider_id", rec.ID, "error", err)
		}
	})
}

// persistReputation saves a provider's current reputation to the store.
// Called asynchronously to avoid blocking the hot path.
func (r *Registry) persistReputation(p *Provider) {
	if r.store == nil {
		return
	}
	saferun.Go(r.logger, "registry.persistReputation", func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		p.mu.Lock()
		rep := store.ReputationRecord{
			TotalJobs:          p.Reputation.TotalJobs,
			SuccessfulJobs:     p.Reputation.SuccessfulJobs,
			FailedJobs:         p.Reputation.FailedJobs,
			TotalUptimeSeconds: int64(p.Reputation.TotalUptime / time.Second),
			AvgResponseTimeMs:  int64(p.Reputation.AvgResponseTime / time.Millisecond),
			ChallengesPassed:   p.Reputation.ChallengesPassed,
			ChallengesFailed:   p.Reputation.ChallengesFailed,
		}
		p.mu.Unlock()

		if err := r.store.UpsertReputation(ctx, p.ID, rep); err != nil {
			r.logger.Warn("failed to persist reputation", "provider_id", p.ID, "error", err)
		}
	})
}
