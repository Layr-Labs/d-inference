package registry

import (
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	CacheRoutingOff = "off"
	CacheRoutingOn  = "on"

	defaultCacheRoutingTTL           = 10 * time.Minute
	defaultCacheRoutingMaxHolders    = 4
	defaultCacheRoutingActivationPct = 100.0
	defaultCacheRoutingMaxPlanQPS    = 0.0
	maxCacheRoutingPlanQPS           = 1_000_000.0
	cacheRoutingAttemptTTL           = 2 * time.Minute
	cacheRoutingInFlightAttemptTTL   = 2 * time.Hour
	cacheRoutingSweepInterval        = 30 * time.Second
	// cacheRoutingSizingTTL is the longest holder TTL the in-memory caps below
	// are sized for. Providers keep cache files for 30 minutes, so a longer
	// routing TTL would only retain evidence for files that are gone. It is a
	// sizing basis, not a limit: a longer TTL is accepted with a warning
	// (warnCacheRoutingTTL).
	cacheRoutingSizingTTL = 30 * time.Minute
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
	// the 1,024-token stride and its final one (cacheDemandAnchors). Measured
	// over the production prompt lengths with every prompt distinct
	// (TestCacheDemandCapCoversMeasuredPlanMix): 7.11 entries per plan for
	// gpt-oss-20b and 3.85 for gemma. The index expires on the routing TTL, so
	// it is sized for cacheRoutingSizingTTL: 60 plans/s × 7.11 × 1,800 s =
	// 768,000; 1,000,000 leaves 1.3× headroom. An index that turns over before
	// the TTL reports a repeated prefix as novel, and the provider then skips
	// writing it. Measured (BenchmarkCacheDemandMemory, settled heap): 200 B
	// per entry, which is the 43-byte base64url HMAC key, a list.Element, a
	// boxed cacheDemandEntry and a map slot, so a full index is about 191 MiB.
	cacheDemandMaxEntries                 = 1_000_000
	cacheRoutingMaxAttempts               = 50_000
	cacheRoutingMaxReceiptTokens          = 1_000_000
	cacheRoutingMaxStageMs                = 10 * 60 * 1000.0
	cacheRoutingMemoryTTL                 = 30 * time.Second
	cacheRoutingMaxCheckpointReadyAnchors = 16
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
		owner := pr.cacheAttempt.Load()
		return owner != nil && owner.dispatchState.Load() != cacheDispatchCold
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

type cacheHolder struct {
	ProviderID              string
	Provider                *Provider
	ModelID                 string
	ModelAggregateHash      string
	PromptContractID        string
	CacheEpoch              string
	Anchor                  protocol.PrefixCacheAnchor
	RequiredRecomputeTokens int
	StageMs                 float64
	stageMeasurement        *cacheStageMeasurement
	UpdatedAt               time.Time
	ExpiresAt               time.Time
}

type cacheAttempt struct {
	RequestID             string
	ProviderID            string
	Provider              *Provider
	Model                 string
	ExpiresAt             time.Time
	CreatedAt             time.Time
	LookupSeen            bool
	V2                    bool
	Plan                  CachePlan
	V2Capability          protocol.PrefixCacheV2Capability
	MemoryCapability      protocol.PrefixCacheV2Capability
	MemoryLookupSeen      bool
	MemoryLastReadyAnchor protocol.PrefixCacheAnchor
	ExpectedPrompt        protocol.PrefixCacheAnchor
	ExpectedBoundaries    map[int]string
	LastReadyAnchor       protocol.PrefixCacheAnchor
}

type cacheV2SequenceKey struct {
	ProviderID string
	ModelID    string
	CacheEpoch string
	Tier       string
}

type cacheV2ProviderModelKey struct {
	ProviderID string
	ModelID    string
	Tier       string
}

type cacheRoutingHint struct {
	generation *cacheRoutingGeneration
	ExpiresAt  time.Time
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

type cacheHolderRemovalReason string

const (
	cacheHolderRemovalTTL              cacheHolderRemovalReason = "ttl"
	cacheHolderRemovalDisconnect       cacheHolderRemovalReason = "disconnect"
	cacheHolderRemovalEpochChange      cacheHolderRemovalReason = "epoch_change"
	cacheHolderRemovalCapabilityChange cacheHolderRemovalReason = "capability_change"
	cacheHolderRemovalProofMismatch    cacheHolderRemovalReason = "proof_mismatch"
	cacheHolderRemovalMissInvalidation cacheHolderRemovalReason = "miss_invalidation"
	cacheHolderRemovalCapacityEviction cacheHolderRemovalReason = "capacity_eviction"
	// A hit proven below a recorded deeper boundary. Kept apart from
	// miss_invalidation: the provider may still store the deeper file and
	// have skipped it under a stage cap, which the wire cannot distinguish
	// from an eviction.
	cacheHolderRemovalShorterHit cacheHolderRemovalReason = "shorter_hit"
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
type cacheAttemptOrderEntry struct {
	nonce      string
	providerID string
	expiresAt  time.Time
	index      int
}

type cacheAttemptOrderHeap []*cacheAttemptOrderEntry

func (h cacheAttemptOrderHeap) Len() int { return len(h) }

func (h cacheAttemptOrderHeap) Less(i, j int) bool {
	if h[i].expiresAt.Equal(h[j].expiresAt) {
		return h[i].nonce < h[j].nonce
	}
	return h[i].expiresAt.Before(h[j].expiresAt)
}

func (h cacheAttemptOrderHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].index = i
	h[j].index = j
}

func (h *cacheAttemptOrderHeap) Push(value any) {
	entry := value.(*cacheAttemptOrderEntry)
	entry.index = len(*h)
	*h = append(*h, entry)
}

func (h *cacheAttemptOrderHeap) Pop() any {
	old := *h
	last := len(old) - 1
	entry := old[last]
	old[last] = nil
	entry.index = -1
	*h = old[:last]
	return entry
}

type cacheHolderRef struct {
	key        string
	providerID string
}

type cacheHolderOrderEntry struct {
	ref       cacheHolderRef
	expiresAt time.Time
	index     int
}

type cacheHolderOrderHeap []*cacheHolderOrderEntry

func (h cacheHolderOrderHeap) Len() int { return len(h) }

func (h cacheHolderOrderHeap) Less(i, j int) bool {
	if !h[i].expiresAt.Equal(h[j].expiresAt) {
		return h[i].expiresAt.Before(h[j].expiresAt)
	}
	if h[i].ref.key != h[j].ref.key {
		return h[i].ref.key < h[j].ref.key
	}
	return h[i].ref.providerID < h[j].ref.providerID
}

func (h cacheHolderOrderHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].index = i
	h[j].index = j
}

func (h *cacheHolderOrderHeap) Push(value any) {
	entry := value.(*cacheHolderOrderEntry)
	entry.index = len(*h)
	*h = append(*h, entry)
}

func (h *cacheHolderOrderHeap) Pop() any {
	old := *h
	last := len(old) - 1
	entry := old[last]
	old[last] = nil
	entry.index = -1
	*h = old[:last]
	return entry
}

type cacheRoutingTracker struct {
	demand      *cacheDemandTracker
	generation  *cacheRoutingGeneration
	mu          sync.Mutex
	ttl         time.Duration
	maxHolders  int
	maxEntries  int
	maxAttempts int
	holderCount int
	lastSweep   time.Time
	// sweepBacklog is set when a sweep ran out of budget with expired entries
	// left; the next tracker operation then continues without waiting for the
	// interval.
	sweepBacklog        bool
	holders             map[string]map[string]cacheHolder
	attempts            map[string]cacheAttempt
	holderOrder         cacheHolderOrderHeap
	holderOrderByRef    map[cacheHolderRef]*cacheHolderOrderEntry
	attemptOrder        cacheAttemptOrderHeap
	attemptOrderByNonce map[string]*cacheAttemptOrderEntry
	// The per-provider indexes hold the same order entries as the heaps and
	// change only where the heaps change, so a disconnect or a capability
	// change visits that provider's entries instead of every bucket and
	// attempt (cache_provider_index.go).
	holdersByProvider  map[string]map[*cacheHolderOrderEntry]struct{}
	attemptsByProvider map[string]map[*cacheAttemptOrderEntry]struct{}
	v2Sequences        map[cacheV2SequenceKey]uint64
	rejectedV2         map[cacheV2ProviderModelKey]cacheV2Fence
	fencesApplied      uint64
	fencesExpired      uint64
	ssdLookups         uint64
	ssdHits            uint64
	ssdMisses          uint64
	ssdDonations       uint64
	holderAdded        uint64
	holderRemoved      map[string]uint64
	donationOutcomes   map[string]uint64
	// clock is read outside t.mu on every receipt; tests replace it before
	// traffic, so it is atomic rather than lock-guarded. Nil means time.Now.
	clock atomic.Pointer[func() time.Time]
}

func (t *cacheRoutingTracker) now() time.Time {
	if clock := t.clock.Load(); clock != nil {
		return (*clock)()
	}
	return time.Now()
}

// SetCacheRoutingClockForTest replaces the clock the exact-cache tracker uses
// for attempt and receipt timestamps, holder expiry at receipt and at routing,
// proof-fence windows and the lifecycle status. Demand observation,
// activation sampling and TTFT calibration keep the wall clock. It applies to
// the current tracker only; ConfigureCacheRouting installs a fresh one.
func (r *Registry) SetCacheRoutingClockForTest(now func() time.Time) {
	if r == nil || now == nil {
		return
	}
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	if tracker != nil {
		tracker.clock.Store(&now)
	}
}

func newCacheRoutingTracker(ttl time.Duration, maxHolders int) *cacheRoutingTracker {
	if ttl <= 0 {
		ttl = defaultCacheRoutingTTL
	}
	if maxHolders <= 0 {
		maxHolders = defaultCacheRoutingMaxHolders
	}
	return &cacheRoutingTracker{
		generation: &cacheRoutingGeneration{},
		demand:     newCacheDemandTracker(cacheDemandMaxEntries, ttl),
		ttl:        ttl, maxHolders: maxHolders, maxEntries: cacheRoutingMaxEntries, maxAttempts: cacheRoutingMaxAttempts,
		holders: make(map[string]map[string]cacheHolder), attempts: make(map[string]cacheAttempt),
		holderOrderByRef: make(map[cacheHolderRef]*cacheHolderOrderEntry), attemptOrderByNonce: make(map[string]*cacheAttemptOrderEntry),
		holdersByProvider:  make(map[string]map[*cacheHolderOrderEntry]struct{}),
		attemptsByProvider: make(map[string]map[*cacheAttemptOrderEntry]struct{}),
		v2Sequences:        make(map[cacheV2SequenceKey]uint64),
		rejectedV2:         make(map[cacheV2ProviderModelKey]cacheV2Fence),
		holderRemoved:      make(map[string]uint64),
		donationOutcomes:   make(map[string]uint64),
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
	DemandEntries      int    `json:"demand_entries"`
	DemandCapEvictions uint64 `json:"demand_cap_evictions"`
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
	// The demand index has its own lock; it is never taken with the tracker's.
	demandEntries, demandCapEvictions := tracker.demand.stats()
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	holderRemoved := zeroUint64Buckets(CacheHolderRemovalReasons())
	for reason, count := range tracker.holderRemoved {
		holderRemoved[reason] = count
	}
	donationOutcomes := zeroUint64Buckets(prefixCacheDonationOutcomes)
	for outcome, count := range tracker.donationOutcomes {
		donationOutcomes[outcome] = count
	}
	// Settle lapsed windows first so fences_expired and fenced_capabilities
	// agree within one scrape.
	fenced := tracker.sweepFencesLocked(tracker.now())
	return CacheRoutingLifecycleStatus{
		SSDLookups: tracker.ssdLookups, SSDHits: tracker.ssdHits,
		SSDMisses: tracker.ssdMisses, SSDDonations: tracker.ssdDonations,
		HolderAdded: tracker.holderAdded, HolderRemoved: holderRemoved,
		DonationOutcomes: donationOutcomes,
		FencesApplied:    tracker.fencesApplied, FencesExpired: tracker.fencesExpired,
		FencedCapabilities: fenced,
		DemandEntries:      demandEntries, DemandCapEvictions: demandCapEvictions,
	}
}

func zeroUint64Buckets(values []string) map[string]uint64 {
	result := make(map[string]uint64, len(values))
	for _, value := range values {
		result[value] = 0
	}
	return result
}

func (t *cacheRoutingTracker) recordDonationOutcomes(deltas map[string]uint64) {
	if t == nil || len(deltas) == 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for outcome, delta := range deltas {
		if delta == 0 || !containsFixed(prefixCacheDonationOutcomes, outcome) {
			continue
		}
		current := t.donationOutcomes[outcome]
		if ^uint64(0)-current < delta {
			t.donationOutcomes[outcome] = ^uint64(0)
		} else {
			t.donationOutcomes[outcome] = current + delta
		}
	}
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
	tracker := newCacheRoutingTracker(cfg.TTL, cfg.MaxHolders)
	activation := newCacheActivationGate(cfg.ActivationPct, cfg.MaxPlanQPS)
	r.mu.Lock()
	previous := r.cacheRouting
	if previous != nil {
		previous.generation.revoked.Store(true)
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
	return CacheRoutingConfig{
		Mode:             r.cacheRoutingMode,
		AllowedArtifacts: r.cacheRoutingAllowedArtifacts.snapshot(),
		ActivationPct:    r.cacheActivation.percent,
		MaxPlanQPS:       r.cacheActivation.maxQPS,
		TTL:              r.cacheRouting.ttl,
		MaxHolders:       r.cacheRouting.maxHolders,
		MaxDiscountMs:    cloneCacheScoreLimit(r.cacheRoutingMaxDiscountMs),
		MaxCostFraction:  cloneCacheScoreLimit(r.cacheRoutingMaxCostFraction),
	}
}
