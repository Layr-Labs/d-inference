package registry

import (
	"context"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// AttestationSummary provides aggregate attestation status for a model's providers.
type AttestationSummary struct {
	SecureEnclave bool `json:"secure_enclave"`
	SIPEnabled    bool `json:"sip_enabled"`
	SecureBoot    bool `json:"secure_boot"`
}

// AggregateModel is a deduplicated model entry for the /v1/models endpoint.
type AggregateModel struct {
	ID                string              `json:"id"`
	ModelType         string              `json:"model_type"`
	Quantization      string              `json:"quantization"`
	Providers         int                 `json:"providers"`          // number of providers offering this model
	AttestedProviders int                 `json:"attested_providers"` // number of attested providers
	TrustLevel        TrustLevel          `json:"trust_level"`        // highest trust level among providers
	Attestation       *AttestationSummary `json:"attestation,omitempty"`
}

// ListModels returns deduplicated models from all online providers.
func (r *Registry) ListModels() []AggregateModel {
	r.mu.RLock()
	defer r.mu.RUnlock()

	type modelAgg struct {
		modelType     string
		quantization  string
		count         int
		attestedCount int
		highestTrust  TrustLevel
		secureEnclave bool
		sipEnabled    bool
		secureBoot    bool
	}

	// Aggregate by model ID only — consumers request by ID, so providers
	// offering the same model ID should be counted together regardless of
	// minor metadata differences.
	agg := make(map[string]*modelAgg)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		attested := p.Attested
		attestResult := p.AttestationResult
		privateReady := r.providerSupportsPrivateTextLocked(p)
		privateOnly := p.PrivateOnly
		// p.Models is replaced copy-on-write by UpdateModelWeightHashes (which
		// holds only p.mu, not r.mu), so snapshot it here under p.mu rather than
		// ranging the field after unlock.
		models := make([]protocol.ModelInfo, len(p.Models))
		copy(models, p.Models)
		p.mu.Unlock()

		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		// Private-only providers serve only their owner's self-route traffic, so
		// they must not appear in or inflate the public /v1/models aggregation.
		if privateOnly {
			continue
		}
		if !r.trustMeetsMinimum(trust) || !privateReady {
			continue
		}
		for _, m := range models {
			if !r.modelAllowedByCatalogLocked(m) {
				continue
			}
			k := m.ID
			a, ok := agg[k]
			if !ok {
				a = &modelAgg{
					modelType:    m.ModelType,
					quantization: m.Quantization,
					highestTrust: TrustNone,
				}
				agg[k] = a
			}
			a.count++

			// Update highest trust level
			if trustRank(trust) > trustRank(a.highestTrust) {
				a.highestTrust = trust
			}

			if attested && attestResult != nil {
				a.attestedCount++
				a.secureEnclave = a.secureEnclave || attestResult.SecureEnclaveAvailable
				a.sipEnabled = a.sipEnabled || attestResult.SIPEnabled
				a.secureBoot = a.secureBoot || attestResult.SecureBootEnabled
			}
		}
	}

	models := make([]AggregateModel, 0, len(agg))
	for k, a := range agg {
		am := AggregateModel{
			ID:                k,
			ModelType:         a.modelType,
			Quantization:      a.quantization,
			Providers:         a.count,
			AttestedProviders: a.attestedCount,
			TrustLevel:        a.highestTrust,
		}
		if a.attestedCount > 0 {
			am.Attestation = &AttestationSummary{
				SecureEnclave: a.secureEnclave,
				SIPEnabled:    a.sipEnabled,
				SecureBoot:    a.secureBoot,
			}
		}
		models = append(models, am)
	}

	return models
}

// ModelCountryCodes returns the sorted, de-duplicated ISO 3166-1 alpha-2
// country codes of online providers serving the given model. Used to populate
// the OpenRouter "datacenters" field. Only routing-eligible providers count —
// the same gates as ListModels (online, meets the minimum trust level, and
// private-text ready) — so a country whose providers can't actually serve the
// model is not advertised. Providers without a known location are skipped.
func (r *Registry) ModelCountryCodes(modelID string) []string {
	r.mu.RLock()
	defer r.mu.RUnlock()

	seen := make(map[string]bool)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		privateReady := r.providerSupportsPrivateTextLocked(p)
		var cc string
		if p.Location != nil {
			cc = strings.ToUpper(strings.TrimSpace(p.Location.CountryCode))
		}
		serves := false
		if cc != "" {
			for i := range p.Models {
				if p.Models[i].ID == modelID {
					serves = true
					break
				}
			}
		}
		p.mu.Unlock()
		if !serves {
			continue
		}
		// Apply the same routing-eligibility gates as ListModels.
		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if !r.trustMeetsMinimum(trust) || !privateReady {
			continue
		}
		seen[cc] = true
	}
	if len(seen) == 0 {
		return nil
	}
	out := make([]string, 0, len(seen))
	for c := range seen {
		out = append(out, c)
	}
	sort.Strings(out)
	return out
}

// trustRank returns a numeric rank for trust levels (higher = more trusted).
// Returns -1 for unknown/invalid trust levels.
func trustRank(t TrustLevel) int {
	switch t {
	case TrustHardware:
		return 2
	case TrustSelfSigned:
		return 1
	case TrustNone:
		return 0
	default:
		return -1
	}
}

// RecordJobSuccess records a successful job completion for the provider's reputation.
func (r *Registry) RecordJobSuccess(providerID string, latency time.Duration) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordJobSuccess()
	p.Reputation.RecordLatency(latency)
	p.mu.Unlock()

	// Persist reputation.
	r.persistReputation(p)
}

// RecordLatency folds a per-request responsiveness sample into the provider's
// latency EWMA without persisting a pre-terminal reputation row.
func (r *Registry) RecordLatency(providerID string, latency time.Duration) {
	if latency <= 0 {
		return
	}
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordLatency(latency)
	p.mu.Unlock()
}

// RecordJobFailure records a failed job for the provider's reputation.
func (r *Registry) RecordJobFailure(providerID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordJobFailure()
	p.mu.Unlock()

	// Persist reputation.
	r.persistReputation(p)
}

// ProviderCount returns the number of registered providers.
// modelProviderInc increments the provider count for a model. Must be called
// with r.mu held.
func (r *Registry) modelProviderInc(model string) {
	r.modelProvidersMu.Lock()
	c, ok := r.modelProviders[model]
	if !ok {
		c = &atomic.Int64{}
		r.modelProviders[model] = c
	}
	r.modelProvidersMu.Unlock()
	c.Add(1)
}

// modelProviderDec decrements the provider count for a model. Must be called
// with r.mu held.
func (r *Registry) modelProviderDec(model string) {
	r.modelProvidersMu.Lock()
	c, ok := r.modelProviders[model]
	r.modelProvidersMu.Unlock()
	if ok {
		v := c.Add(-1)
		if v <= 0 {
			r.modelProvidersMu.Lock()
			delete(r.modelProviders, model)
			r.modelProvidersMu.Unlock()
		}
	}
}

// OnlineCount returns the number of online providers.
func (r *Registry) OnlineCount() int64 {
	return r.onlineCount.Load()
}

// CodeAttestationCoverage reports how many currently online (non-offline,
// non-untrusted) providers have passed APNs code-identity attestation, plus the
// online total. Operators watch this during the grace window to judge when it is
// safe to let the APNS_ENFORCE_AFTER deadline pass — after which every
// un-attested provider (incl. all headless / pre-0.6.0 boxes) is derouted.
// Thread-safe.
func (r *Registry) CodeAttestationCoverage() (codeAttested, online int) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		p.mu.Lock()
		if p.Status != StatusOffline && p.Status != StatusUntrusted {
			online++
			if p.CodeAttested {
				codeAttested++
			}
		}
		p.mu.Unlock()
	}
	return codeAttested, online
}

// ModelProviderSnapshot returns a snapshot of model_id -> provider count.
func (r *Registry) ModelProviderSnapshot() map[string]int64 {
	r.modelProvidersMu.Lock()
	snap := make(map[string]int64, len(r.modelProviders))
	for model, c := range r.modelProviders {
		if v := c.Load(); v > 0 {
			snap[model] = v
		}
	}
	r.modelProvidersMu.Unlock()
	return snap
}

func (r *Registry) ProviderCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.providers)
}

func (r *Registry) ProviderCountByVersion() map[string]int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	counts := make(map[string]int)
	for _, p := range r.providers {
		p.mu.Lock()
		online := p.Status != StatusOffline && p.Status != StatusUntrusted
		p.mu.Unlock()
		if !online {
			continue
		}
		ver := p.Version
		if ver == "" {
			ver = "unknown"
		}
		counts[ver]++
	}
	return counts
}

type TrustStatusCount struct {
	TrustLevel string
	Status     string
	Count      int
}

func (r *Registry) ProviderCountByTrustStatus() []TrustStatusCount {
	r.mu.RLock()
	defer r.mu.RUnlock()
	type key struct{ trust, status string }
	counts := make(map[key]int)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		p.mu.Unlock()
		if status == StatusOffline {
			continue
		}
		counts[key{string(trust), string(status)}]++
	}
	out := make([]TrustStatusCount, 0, len(counts))
	for k, n := range counts {
		out = append(out, TrustStatusCount{TrustLevel: k.trust, Status: k.status, Count: n})
	}
	return out
}

func (r *Registry) ProviderCountByMDMFailure() map[string]int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	counts := make(map[string]int)
	for _, p := range r.providers {
		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		reason := p.MDMFailureReason
		p.mu.Unlock()
		if status == StatusOffline || trust == TrustHardware {
			continue
		}
		if reason == "" {
			reason = "pending"
		}
		counts[reason]++
	}
	return counts
}

// FleetSnapshot is the read-only summary used by metrics polling. We
// don't lock individual providers — counts may be off-by-one under
// heavy churn — that's acceptable for gauges.
type FleetSnapshot struct {
	Connected  int
	Idle       int
	QueueDepth int
}

// Snapshot returns aggregate counts for /metrics gauges. Cheap enough
// to call every few seconds. Takes the registry's read lock for the
// outer iteration AND each provider's mutex briefly to read Status and
// pending count — those fields are written under p.mu elsewhere
// (Heartbeat, AddPending, RemovePending), so reading them without
// p.mu is a data race even if the gauge value is only advisory.
func (r *Registry) Snapshot() FleetSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	idle := 0
	for _, p := range r.providers {
		p.mu.Lock()
		isIdle := p.Status == StatusOnline && len(p.pendingReqs) == 0
		p.mu.Unlock()
		if isIdle {
			idle++
		}
	}
	q := 0
	if r.queue != nil {
		q = r.queue.TotalSize()
	}
	return FleetSnapshot{
		Connected:  len(r.providers),
		Idle:       idle,
		QueueDepth: q,
	}
}

// ModelCapacity describes the live capacity for a single model.
type ModelCapacity struct {
	ModelID              string  `json:"id"`
	Ready                bool    `json:"ready"`                  // at least one routable provider with headroom
	CanAccept            bool    `json:"can_accept"`             // ready AND queue not full
	RoutableProviders    int     `json:"routable_providers"`     // passed all gates
	WarmProviders        int     `json:"warm_providers"`         // model loaded (slot state "running" or "idle")
	ColdProviders        int     `json:"cold_providers"`         // model available but not loaded
	ActiveRequests       int     `json:"active_requests"`        // in-flight across fleet
	QueuedRequests       int     `json:"queued_requests"`        // waiting in coordinator queue
	QueueLimit           int     `json:"queue_limit"`            // max queue depth per model
	AggregateTPS         float64 `json:"aggregate_tps"`          // sum of effective decode TPS
	EstimatedTTFTMs      int64   `json:"estimated_ttft_ms"`      // best-case TTFT from lowest-cost warm provider
	TokenBudgetRemaining int64   `json:"token_budget_remaining"` // aggregate free budget across providers
	TokenBudgetTotal     int64   `json:"token_budget_total"`     // aggregate total budget
}

// providerCapSnap is a per-provider snapshot collected under the registry
// lock, then aggregated into ModelCapacity outside the lock.
type providerCapSnap struct {
	model                 string
	warm                  bool
	hasHeadroom           bool // pending < maxConcurrency
	effectiveTPS          float64
	prefillTPS            float64
	activeRequests        int // numRunning + numWaiting from backend slot, or pendingCount
	backlogTokens         float64
	activeTokenBudgetMax  int64
	activeTokenBudgetUsed int64
	queuedTokenBudget     int64
}

// ModelCapacitySnapshot returns a capacity snapshot for every model served
// by at least one provider. Providers must pass the same routing gates as
// snapshotProviderLocked (status, trust, runtime, privacy, challenge
// freshness, concurrency headroom) to be counted as routable.
func (r *Registry) ModelCapacitySnapshot() []ModelCapacity {
	now := time.Now()

	// Phase 1: collect per-provider snapshots under the lock.
	var snaps []providerCapSnap

	r.mu.RLock()
	for _, p := range r.providers {
		p.mu.Lock()

		// Apply the same gates as snapshotProviderLocked. Private-only machines
		// never serve the public fleet, so they do not count toward public
		// model capacity.
		if p.Status == StatusOffline || p.Status == StatusUntrusted {
			p.mu.Unlock()
			continue
		}
		if p.PrivateOnly {
			p.mu.Unlock()
			continue
		}
		if trustRank(p.TrustLevel) < trustRank(r.MinTrustLevel) {
			p.mu.Unlock()
			continue
		}
		if !p.RuntimeVerified {
			p.mu.Unlock()
			continue
		}
		if !r.providerSupportsPrivateTextLocked(p) {
			p.mu.Unlock()
			continue
		}
		if p.LastChallengeVerified.IsZero() || now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
			p.mu.Unlock()
			continue
		}

		decodeTPS := resolvedDecodeTPS(p)
		prefillTPS := resolvedPrefillTPS(p)

		// Enumerate every model this provider serves.
		for _, m := range p.Models {
			if !r.modelAllowedByCatalogLocked(m) {
				continue
			}
			hasHeadroom := p.hasConcurrencyHeadroomForModelLocked(m.ID)
			// Count only pending requests for this specific model, not the
			// total across all models. Using the total inflates
			// activeRequests for multi-model providers.
			modelPending := 0
			for _, pr := range p.pendingReqs {
				if pr.Model == m.ID {
					modelPending++
				}
			}

			snap := providerCapSnap{
				model:          m.ID,
				hasHeadroom:    hasHeadroom,
				effectiveTPS:   decodeTPS,
				prefillTPS:     prefillTPS,
				activeRequests: modelPending,
			}

			// Check backend capacity for this model's slot.
			if p.BackendCapacity != nil {
				for _, slot := range p.BackendCapacity.Slots {
					if slot.Model != m.ID {
						continue
					}
					snap.warm = slotStateModelLoaded(slot.State)
					slotActive := int(slot.NumRunning) + int(slot.NumWaiting)
					if slotActive > snap.activeRequests {
						snap.activeRequests = slotActive
					}
					if slot.ObservedDecodeTPS > 0 {
						snap.effectiveTPS = slot.ObservedDecodeTPS
					}
					snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
					snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
					snap.queuedTokenBudget = slot.QueuedTokenBudget
					snap.backlogTokens = float64(slot.MaxTokensPotential)
					break
				}
			} else {
				// Without backend capacity, warm if currently serving this model.
				snap.warm = p.CurrentModel == m.ID
			}

			snaps = append(snaps, snap)
		}
		p.mu.Unlock()
	}
	r.mu.RUnlock()

	// Phase 2: aggregate per-model outside the lock.
	type modelAgg struct {
		routable         int
		warm             int
		cold             int
		activeRequests   int
		aggregateTPS     float64
		budgetRemaining  int64
		budgetTotal      int64
		bestWarmTTFTMs   int64 // -1 = not set
		bestColdTTFTMs   int64 // -1 = not set
		anyImmediateSlot bool  // at least one provider with headroom
	}
	agg := make(map[string]*modelAgg)
	for _, s := range snaps {
		a, ok := agg[s.model]
		if !ok {
			a = &modelAgg{bestWarmTTFTMs: -1, bestColdTTFTMs: -1}
			agg[s.model] = a
		}
		if s.warm {
			a.warm++
		} else {
			a.cold++
		}
		a.activeRequests += s.activeRequests
		a.aggregateTPS += s.effectiveTPS
		if s.activeTokenBudgetMax > 0 {
			headroom := s.activeTokenBudgetMax - s.activeTokenBudgetUsed - s.queuedTokenBudget
			if headroom < 0 {
				headroom = 0
			}
			a.budgetRemaining += headroom
			a.budgetTotal += s.activeTokenBudgetMax
		}
		// Routable providers require both concurrency headroom AND token-budget
		// headroom. A provider with exhausted token budget should not make the
		// model appear immediately ready.
		hasBudgetHeadroom := s.activeTokenBudgetMax <= 0 ||
			s.activeTokenBudgetUsed+s.queuedTokenBudget < s.activeTokenBudgetMax
		if s.hasHeadroom && hasBudgetHeadroom {
			a.routable++
			a.anyImmediateSlot = true
		}

		// Estimate TTFT for this provider: prefill 500 tokens + backlog drain.
		const defaultPromptTokens = 500
		ttftMs := int64(0)
		if s.prefillTPS > 0 {
			ttftMs = int64(float64(defaultPromptTokens) / s.prefillTPS * 1000)
		}
		if s.effectiveTPS > 0 {
			ttftMs += int64(s.backlogTokens / s.effectiveTPS * 1000)
		}
		if s.warm {
			if a.bestWarmTTFTMs < 0 || ttftMs < a.bestWarmTTFTMs {
				a.bestWarmTTFTMs = ttftMs
			}
		} else {
			coldTTFT := ttftMs + 20_000 // 20s cold-start penalty
			if a.bestColdTTFTMs < 0 || coldTTFT < a.bestColdTTFTMs {
				a.bestColdTTFTMs = coldTTFT
			}
		}
	}

	// Phase 3: read queue sizes (separate lock, safe to call after releasing r.mu).
	queueLimit := 0
	if r.queue != nil {
		queueLimit = r.queue.MaxSize()
	}

	result := make([]ModelCapacity, 0, len(agg))
	for model, a := range agg {
		queued := 0
		if r.queue != nil {
			queued = r.queue.QueueSize(model)
		}
		ready := a.routable > 0
		canAccept := ready && (queued < queueLimit || a.anyImmediateSlot)

		ttft := a.bestWarmTTFTMs
		if ttft < 0 {
			ttft = a.bestColdTTFTMs
		}
		if ttft < 0 {
			ttft = 0
		}

		result = append(result, ModelCapacity{
			ModelID:              model,
			Ready:                ready,
			CanAccept:            canAccept,
			RoutableProviders:    a.routable,
			WarmProviders:        a.warm,
			ColdProviders:        a.cold,
			ActiveRequests:       a.activeRequests,
			QueuedRequests:       queued,
			QueueLimit:           queueLimit,
			AggregateTPS:         a.aggregateTPS,
			EstimatedTTFTMs:      ttft,
			TokenBudgetRemaining: a.budgetRemaining,
			TokenBudgetTotal:     a.budgetTotal,
		})
	}
	return result
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

// StartEvictionLoop starts a background goroutine that removes providers
// that haven't sent a heartbeat within the given timeout. It stops when
// the context is cancelled.
func (r *Registry) StartEvictionLoop(ctx context.Context, timeout time.Duration) {
	ticker := time.NewTicker(timeout / 3)
	saferun.Go(r.logger, "registry.evictionLoop", func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				r.evictStale(timeout)
			}
		}
	})
}

func (r *Registry) evictStale(timeout time.Duration) {
	now := time.Now()

	// Scan under the write lock: we both READ LastHeartbeat and REBUILD
	// evictStrikes. Collect every provider's heartbeat age for the summary, and
	// decide who to evict: a provider is reaped only after it is stale on TWO
	// consecutive sweeps (strike >= 2), so a single transient stall that ages
	// many timestamps at once gives the fleet a sweep to recover instead of a
	// mass reap.
	r.mu.Lock()
	fleet := len(r.providers)
	ages := make([]time.Duration, 0, fleet)
	nextStrikes := make(map[string]int, len(r.evictStrikes))
	var toEvict []string
	var evictAges []time.Duration
	for id, p := range r.providers {
		p.mu.Lock()
		lastHeartbeat := p.LastHeartbeat
		p.mu.Unlock()
		age := now.Sub(lastHeartbeat)
		ages = append(ages, age)
		if age > timeout {
			strikes := r.evictStrikes[id] + 1
			if strikes >= evictStrikeThreshold {
				toEvict = append(toEvict, id)
				evictAges = append(evictAges, age)
			} else {
				nextStrikes[id] = strikes // carry the strike to next sweep
			}
		}
	}
	r.evictStrikes = nextStrikes
	r.mu.Unlock()

	if len(ages) > 0 {
		amin, amed, ap90, amax := durationStats(ages)
		// A tight evicted-age spread (emax-emin small) means many providers went
		// stale at the same instant — a coordinator-side stall. A broad spread
		// means independent provider sleeps. The summary makes that diagnosable.
		emin, _, _, emax := durationStats(evictAges)
		r.logger.Info("eviction sweep",
			"fleet", fleet,
			"evicting", len(toEvict),
			"hb_age_min_s", int(amin.Seconds()),
			"hb_age_p50_s", int(amed.Seconds()),
			"hb_age_p90_s", int(ap90.Seconds()),
			"hb_age_max_s", int(amax.Seconds()),
			"evicted_age_min_s", int(emin.Seconds()),
			"evicted_age_max_s", int(emax.Seconds()),
		)
	}

	for _, id := range toEvict {
		r.logger.Warn("evicting stale provider", "provider_id", id, "timeout", timeout)
		r.Disconnect(id)
	}
}

// evictStrikeThreshold is how many consecutive stale sweeps trigger eviction.
// With a timeout/3 sweep cadence, 2 strikes ≈ one extra sweep interval of grace.
const evictStrikeThreshold = 2

// durationStats returns min, median, p90, max of ds (zeros for an empty slice).
// Sorts a copy; ds is small (fleet-sized) so this is cheap.
func durationStats(ds []time.Duration) (min, median, p90, max time.Duration) {
	if len(ds) == 0 {
		return 0, 0, 0, 0
	}
	s := make([]time.Duration, len(ds))
	copy(s, ds)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	return s[0], s[len(s)/2], s[(len(s)*9)/10], s[len(s)-1]
}
