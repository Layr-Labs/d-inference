package registry

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/cachedirectory"
)

const (
	CacheRoutingOff = "off"
	CacheRoutingOn  = "on"

	defaultCacheRoutingTTL                = cachedirectory.DefaultTTL
	defaultCacheRoutingMaxHolders         = cachedirectory.DefaultMaxHolders
	defaultCacheRoutingActivationPct      = 100.0
	defaultCacheRoutingMaxPlanQPS         = 0.0
	maxCacheRoutingPlanQPS                = 1_000_000.0
	cacheRoutingAttemptTTL                = cachedirectory.AttemptTTL
	cacheRoutingInFlightAttemptTTL        = cachedirectory.InFlightAttemptTTL
	cacheRoutingSweepInterval             = cachedirectory.SweepInterval
	cacheRoutingMaxEntries                = cachedirectory.MaxEntries
	cacheRoutingMaxAttempts               = cachedirectory.MaxAttempts
	cacheRoutingMaxReceiptTokens          = cachedirectory.MaxReceiptTokens
	cacheRoutingMaxStageMs                = cachedirectory.MaxStageMs
	cacheRoutingMemoryTTL                 = cachedirectory.MemoryTTL
	cacheRoutingMaxCheckpointReadyAnchors = cachedirectory.MaxCheckpointReadyAnchors
)

type CachePlan struct {
	// Advisory only. Neither field supplies cache credit or bypasses proof.
	RepeatedPrefixTokens int
	affinityKey          string
	generation           *cacheRoutingGeneration
	ModelAggregateHash   string
	PromptContractID     string
	CacheScope           string
	PromptTokenCount     int
	Boundaries           []protocol.PrefixCacheAnchor
}

func (p CachePlan) present() bool {
	return p.ModelAggregateHash != "" &&
		p.PromptContractID != "" &&
		p.CacheScope != "" &&
		p.PromptTokenCount > 0 &&
		len(p.Boundaries) > 0
}

// CacheRoutingParticipates reports whether this concrete provider attempt
// received an authenticated reusable-cache scope and receipt nonce. Route
// derivation alone is insufficient: off mode, legacy protocol, a missing catalog
// hash, or a provider/catalog hash mismatch all dispatch uncached and must keep
// contributing ordinary TTFT/reputation feedback.
func (pr *PendingRequest) CacheRoutingParticipates() bool {
	if pr != nil {
		return pr.cacheAttempt.Participates()
	}
	return false
}

// CacheRoutingTelemetryEligible preserves the cache-selection denominator for
// route-derived and selected attempts, independent of whether the selected
// provider could actually participate. This is telemetry-only and never
// suppresses baseline feedback.
func (pr *PendingRequest) CacheRoutingTelemetryEligible() bool {
	return pr != nil && pr.CachePlan.present()
}

type cacheRouteKeys struct {
	route      []byte
	scope      []byte
	activation []byte
}

type cacheRoutingHint struct {
	generation *cacheRoutingGeneration
	// Frozen at holder lookup; pricing never re-reads the clock at reservation.
	EvidenceWeight     float64
	PrefillTokensSaved int
	CachedTokens       int
	StageMs            float64
	Provider           *Provider
	Capability         protocol.PrefixCacheV2Capability
	CapabilityRevision uint64
	Tier               string
}

type cacheRoutingCapability struct {
	Provider           *Provider
	Capability         protocol.PrefixCacheV2Capability
	MemoryCapability   protocol.PrefixCacheV2Capability
	CapabilityRevision uint64
}

type cacheRoutingTracker struct {
	demand     *cacheDemandTracker
	generation *cacheRoutingGeneration
	directory  *cachedirectory.Directory[*Provider]
}

func newCacheRoutingTracker(ttl time.Duration, maxHolders int) *cacheRoutingTracker {
	if ttl <= 0 {
		ttl = defaultCacheRoutingTTL
	}
	if maxHolders <= 0 {
		maxHolders = defaultCacheRoutingMaxHolders
	}
	generation := &cacheRoutingGeneration{}
	return &cacheRoutingTracker{
		generation: generation,
		demand:     newCacheDemandTracker(cacheRoutingMaxEntries, ttl),
		directory:  cachedirectory.New[*Provider](generation, ttl, maxHolders, prefixCacheDonationOutcomes),
	}
}

// CacheRoutingStateCounts exposes aggregate optimizer health without route
// keys, accounts, models, prompts, or provider identities.
func (r *Registry) CacheRoutingStateCounts() (holders, attempts int) {
	if r == nil {
		return 0, 0
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker == nil {
		return 0, 0
	}
	return tracker.directory.StateCounts(time.Now())
}

func (r *Registry) CacheRoutingLifecycleStatus() CacheRoutingLifecycleStatus {
	if r == nil {
		return CacheRoutingLifecycleStatus{}
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker == nil {
		return CacheRoutingLifecycleStatus{}
	}
	return tracker.directory.LifecycleStatus()
}

func (r *Registry) ConfigureCacheRouting(cfg CacheRoutingConfig) error {
	cfg.Mode = strings.ToLower(strings.TrimSpace(cfg.Mode))
	if cfg.Mode == "" {
		cfg.Mode = CacheRoutingOff
	}
	if cfg.TTL == 0 {
		cfg.TTL = defaultCacheRoutingTTL
	}
	if cfg.MaxHolders == 0 {
		cfg.MaxHolders = defaultCacheRoutingMaxHolders
	}
	if err := cfg.Check(); err != nil {
		return err
	}
	var keys cacheRouteKeys
	if cfg.Mode != CacheRoutingOff {
		master, err := decodeCacheMasterKey(cfg.MasterKey)
		if err != nil {
			return err
		}
		keys = deriveCacheKeys(master)
	}
	// Check validated these tuples; compile an owned immutable membership map.
	artifacts, _ := newCacheArtifactAllowlist(cfg.AllowedArtifacts)
	tracker := newCacheRoutingTracker(cfg.TTL, cfg.MaxHolders)
	activation := newCacheActivationGate(cfg.ActivationPct, cfg.MaxPlanQPS)
	r.mu.Lock()
	previous := r.cacheRouting
	if previous != nil {
		previous.generation.Revoke()
	}
	r.cacheRouting = tracker
	r.cacheActivation = activation
	r.cacheRoutingMode = cfg.Mode
	r.cacheRoutingAllowedArtifacts = artifacts
	r.cacheRouteKeys = keys
	r.cacheRoutingMaxDiscountMs = cloneCacheScoreLimit(cfg.MaxDiscountMs)
	r.cacheRoutingMaxCostFraction = cloneCacheScoreLimit(cfg.MaxCostFraction)
	r.mu.Unlock()
	if previous != nil {
		previous.directory.ClearRetired()
	}
	return nil
}

func (r *Registry) CacheRoutingConfigSnapshot() CacheRoutingConfig {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return CacheRoutingConfig{
		Mode:             r.cacheRoutingMode,
		AllowedArtifacts: r.cacheRoutingAllowedArtifacts.snapshot(),
		ActivationPct:    r.cacheActivation.percent,
		MaxPlanQPS:       r.cacheActivation.maxQPS,
		TTL:              r.cacheRouting.directory.Config().TTL,
		MaxHolders:       r.cacheRouting.directory.Config().MaxHolders,
		MaxDiscountMs:    cloneCacheScoreLimit(r.cacheRoutingMaxDiscountMs),
		MaxCostFraction:  cloneCacheScoreLimit(r.cacheRoutingMaxCostFraction),
	}
}
