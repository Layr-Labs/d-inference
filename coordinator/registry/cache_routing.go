package registry

import (
	"strings"
	"time"

	cacheactivation "github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheattempt"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	CacheRoutingOff = "off"
	CacheRoutingOn  = "on"

	defaultCacheRoutingTTL           = cachedemand.DefaultTTL
	defaultCacheRoutingMaxHolders    = 4
	defaultCacheRoutingActivationPct = 100.0
	defaultCacheRoutingMaxPlanQPS    = 0.0
	maxCacheRoutingPlanQPS           = 1_000_000.0
	cacheRoutingAttemptTTL           = cachetracker.AttemptTTL
	cacheRoutingInFlightAttemptTTL   = 2 * time.Hour
	cacheRoutingSweepInterval        = cachetracker.SweepInterval
	// cacheRoutingSizingTTL is the longest holder TTL the in-memory caps below
	// are sized for. Providers keep cache files for 30 minutes, so a longer
	// routing TTL would only retain evidence for files that are gone. It is a
	// sizing basis, not a limit: a longer TTL is accepted with a warning
	// (warnCacheRoutingTTL).
	cacheRoutingSizingTTL = cachedemand.SizingTTL
	// cacheRoutingMaxEntries is the global holder cap. Holders live their whole
	// TTL, so the steady state is creation rate × TTL. Production creates about
	// 7 holders/s and checkpoint geometry is expected to raise that toward
	// 30/s: 30/s × 1,800 s (cacheRoutingSizingTTL) = 54,000. 250,000 leaves
	// more than 4× headroom (about 139/s sustained) before the cap displaces
	// live evidence and shortens the effective TTL. Measured through the
	// receipt path (BenchmarkCacheHolderMemory, settled heap): 1,020 B per
	// donated holder and 1,164 B per holder recorded by a hit, which adds the
	// stage measurement. That covers the holder and its decoded strings, its
	// bucket map, the expiry-heap entry, its by-ref slot and the per-provider
	// index (38 B, BenchmarkCacheProviderIndexMemory), so a full index is
	// about 280 MiB and 54,000 holders about 60 MiB.
	cacheRoutingMaxEntries = 250_000
	// cacheDemandMaxEntries sizes the observed-demand index for the routing TTL
	// at fleet rate, not for the holder cap. A plan records its boundaries on
	// the 1,024-token stride and its final one (cachedemand.Anchors). Measured
	// over the production prompt lengths with every prompt distinct
	// (TestCacheDemandCapCoversMeasuredPlanMix): 7.11 entries per plan for
	// gpt-oss-20b and 3.85 for gemma. The index expires on the routing TTL, so
	// it is sized for cacheRoutingSizingTTL: 60 plans/s × 7.11 × 1,800 s =
	// 768,000; 1,000,000 leaves 1.3× headroom. An index that turns over before
	// the TTL reports a repeated prefix as novel, and the provider then skips
	// writing it. Measured (BenchmarkCacheDemandMemory, settled heap): 200 B
	// per entry, which is the 43-byte base64url HMAC key, a list.Element, a
	// boxed cacheDemandEntry and a map slot, so a full index is about 191 MiB.
	cacheDemandMaxEntries                 = cachedemand.MaxEntries
	cacheRoutingMaxAttempts               = 50_000
	cacheRoutingMaxReceiptTokens          = cachepolicy.MaxReceiptTokens
	cacheRoutingMaxStageMs                = cachepolicy.MaxStageMs
	cacheRoutingMemoryTTL                 = cachetracker.MemoryTTL
	cacheRoutingMaxCheckpointReadyAnchors = cachepolicy.MaxCheckpointReadyAnchors
)

type CachePlan = cacheplan.Plan

// CacheRoutingParticipates reports whether this concrete provider attempt
// received an authenticated reusable-cache scope and receipt nonce. Route
// derivation alone is insufficient: off mode, legacy protocol, a missing catalog
// hash, or a provider/catalog hash mismatch all dispatch uncached and must keep
// contributing ordinary TTFT/reputation feedback.
func (pr *PendingRequest) CacheRoutingParticipates() bool {
	if pr != nil {
		return pr.cachePreparation.Participates()
	}
	return false
}

// CacheRoutingTelemetryEligible preserves the cache-selection denominator for
// route-derived and selected attempts, independent of whether the selected
// provider could actually participate. This is telemetry-only and never
// suppresses baseline feedback.
func (pr *PendingRequest) CacheRoutingTelemetryEligible() bool {
	return pr != nil && pr.CachePlan.Present()
}

type cacheRouteKeys struct {
	route      []byte
	scope      []byte
	activation []byte
	// persistFingerprint is a non-secret marker of the key generation used to
	// fence persisted cache routing rows (cachepersist.Restore).
	persistFingerprint string
}

type cacheHolder = cachetracker.Holder[*Provider]

type cacheAttempt = cachetracker.Attempt[*Provider]

type cacheV2SequenceKey = cachetracker.SequenceKey

type cacheV2ProviderModelKey = cachetracker.FenceKey

// CacheRoutingHint is an immutable routing observation. Its generation binding
// remains private and is revalidated when the scheduler applies its credit.
type CacheRoutingHint struct {
	generation cacheattempt.Gate
	evidence   *cachetracker.HolderEvidence
	ExpiresAt  time.Time
	// Frozen at holder lookup; pricing never re-reads the clock at reservation.
	EvidenceWeight     float64
	PrefillTokensSaved int
	CachedTokens       int
	StageMs            float64
	Provider           *Provider
	Capability         protocol.PrefixCacheV2Capability
	CapabilityRevision cachepeer.Token
	Tier               string
}

type cacheRoutingHint = CacheRoutingHint

type CacheRoutingCapability struct {
	Provider           *Provider
	Capability         protocol.PrefixCacheV2Capability
	MemoryCapability   protocol.PrefixCacheV2Capability
	CapabilityRevision cachepeer.Token
}

type cacheHolderRemovalReason = cachetracker.RemovalReason

const (
	cacheHolderRemovalTTL              = cachetracker.RemovalTTL
	cacheHolderRemovalDisconnect       = cachetracker.RemovalDisconnect
	cacheHolderRemovalEpochChange      = cachetracker.RemovalEpochChange
	cacheHolderRemovalCapabilityChange = cachetracker.RemovalCapabilityChange
	cacheHolderRemovalProofMismatch    = cachetracker.RemovalProofMismatch
	cacheHolderRemovalMissInvalidation = cachetracker.RemovalMissInvalidation
	cacheHolderRemovalCapacityEviction = cachetracker.RemovalCapacityEviction
	// A hit proven below a recorded deeper boundary. Kept apart from
	// miss_invalidation: the provider may still store the deeper file and
	// have skipped it under a stage cap, which the wire cannot distinguish
	// from an eviction.
	cacheHolderRemovalShorterHit = cachetracker.RemovalShorterHit
)

func CacheHolderRemovalReasons() []string {
	return []string{
		string(cacheHolderRemovalTTL),
		string(cacheHolderRemovalDisconnect),
		string(cacheHolderRemovalEpochChange),
		string(cacheHolderRemovalCapabilityChange),
		string(cacheHolderRemovalProofMismatch),
		string(cacheHolderRemovalMissInvalidation),
		string(cacheHolderRemovalCapacityEviction),
		string(cacheHolderRemovalShorterHit),
	}
}

// Both order heaps are min-heaps on expiry, so the head is always the entry
// that lapses first. One structure then serves the TTL sweep (pop while the
// head is expired, O(expired · log n)) and the entry cap (evict the head,
// which forfeits the least remaining lifetime). Creation or update time is
// not a substitute: an attempt's expiry is rewritten when it turns terminal
// (2 h in flight, 2 min after), and resident holders live
// min(ttl, cacheRoutingMemoryTTL) while SSD holders live the full ttl, so
// neither order matches the order of expiry.
type cacheHolderOrderEntry = cacheindex.Entry[cacheindex.HolderRef]

type cacheAttemptOrderEntry = cacheindex.Entry[cacheindex.AttemptRef]

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
	return tracker.stateCounts(tracker.now())
}

// CacheRoutingLifecycleStatus carries aggregate counts only. The fence fields
// count windows, never the providers, models or tiers they quarantined.
type CacheRoutingLifecycleStatus struct {
	SSDLookups         uint64            `json:"ssd_lookups"`
	SSDHits            uint64            `json:"ssd_hits"`
	SSDMisses          uint64            `json:"ssd_misses"`
	SSDDonations       uint64            `json:"ssd_donations"`
	HolderAdded        uint64            `json:"holder_added"`
	HolderRemoved      map[string]uint64 `json:"holder_removed"`
	DonationOutcomes   map[string]uint64 `json:"donation_outcomes"`
	FencesApplied      uint64            `json:"fences_applied"`
	FencesExpired      uint64            `json:"fences_expired"`
	FencedCapabilities int               `json:"fenced_capabilities"`
	// DemandEntries is what the observed-demand index holds now, including
	// expired entries its bounded sweep has not reached. DemandCapEvictions
	// counts entries the cap removed inside their TTL; while it grows, the
	// index is too small and repeated prefixes are reported as novel.
	DemandEntries      int                           `json:"demand_entries"`
	DemandCapEvictions uint64                        `json:"demand_cap_evictions"`
	Persistence        CacheRoutingPersistenceStatus `json:"persistence"`
}

func (r *Registry) CacheRoutingLifecycleStatus() CacheRoutingLifecycleStatus {
	if r == nil {
		return CacheRoutingLifecycleStatus{}
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	persister := r.cachePersister
	r.mu.RUnlock()
	if tracker == nil {
		return CacheRoutingLifecycleStatus{}
	}
	// The demand index has its own lock; it is never taken with the tracker's.
	demandEntries, demandCapEvictions := tracker.demand.stats()
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	holderAdded, holderRemoved := tracker.core.HolderLifecycle(CacheHolderRemovalReasons())
	receipts := tracker.core.ReceiptLifecycle()
	// Settle lapsed windows first so fences_expired and fenced_capabilities
	// agree within one scrape.
	fenced := tracker.sweepFencesLocked(tracker.now())
	fencesApplied, fencesExpired := tracker.proofs.Counts()
	return CacheRoutingLifecycleStatus{
		SSDLookups: receipts.SSDLookups, SSDHits: receipts.SSDHits,
		SSDMisses: receipts.SSDMisses, SSDDonations: receipts.SSDDonations,
		HolderAdded: holderAdded, HolderRemoved: holderRemoved,
		DonationOutcomes: receipts.DonationOutcomes,
		FencesApplied:    fencesApplied, FencesExpired: fencesExpired,
		FencedCapabilities: fenced,
		DemandEntries:      demandEntries, DemandCapEvictions: demandCapEvictions,
		Persistence: persister.Status(),
	}
}

func (t *cacheRoutingTracker) recordDonationOutcomes(deltas map[string]uint64) {
	if t == nil || len(deltas) == 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	t.core.RecordDonationOutcomes(deltas)
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
	r.warnCacheRoutingTTL(cfg)
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
	tracker := newCacheRoutingTrackerWithDependencies(cfg.TTL, cfg.MaxHolders, r.cacheDependencies)
	if r.cacheDependencies.HintQueries != nil {
		tracker.hintQuery = r.cacheDependencies.HintQueries(CacheHintQuery{registry: r, tracker: tracker})
	}
	activation := cacheactivation.New(cfg.ActivationPct, cfg.MaxPlanQPS)
	r.mu.Lock()
	previous := r.cacheRouting
	if previous != nil {
		previous.generation.Retire()
	}
	// A reconfigure keeps the durable copy flowing into the new tracker; the
	// retired tracker stops marking because its generation is revoked.
	tracker.persister = r.cachePersister
	tracker.core.AttachPersistence(r.cachePersister)
	if tracker.persister != nil {
		tracker.demand.setOnTouched(tracker.persister.MarkDemand)
	}
	r.cacheRouting = tracker
	r.cacheActivation = activation
	r.cacheRoutingMode = cfg.Mode
	r.cacheRoutingAllowedArtifacts = artifacts
	r.cacheRouteKeys = keys
	r.cacheRoutingMaxDiscountMs = cloneCacheScoreLimit(cfg.MaxDiscountMs)
	r.cacheRoutingMaxCostFraction = cloneCacheScoreLimit(cfg.MaxCostFraction)
	r.mu.Unlock()
	previous.clearRetired()
	return nil
}

func (r *Registry) CacheRoutingConfigSnapshot() CacheRoutingConfig {
	r.mu.RLock()
	defer r.mu.RUnlock()
	activation := r.cacheActivation.Snapshot()
	return CacheRoutingConfig{
		Mode:             r.cacheRoutingMode,
		AllowedArtifacts: r.cacheRoutingAllowedArtifacts.Snapshot(),
		ActivationPct:    activation.Percent,
		MaxPlanQPS:       activation.MaxPlanQPS,
		TTL:              r.cacheRouting.settings.TTL,
		MaxHolders:       r.cacheRouting.settings.MaxHolders,
		MaxDiscountMs:    cloneCacheScoreLimit(r.cacheRoutingMaxDiscountMs),
		MaxCostFraction:  cloneCacheScoreLimit(r.cacheRoutingMaxCostFraction),
	}
}
