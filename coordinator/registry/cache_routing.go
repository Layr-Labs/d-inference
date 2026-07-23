package registry

import (
	"math"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	CacheRoutingOff = "off"
	CacheRoutingOn  = "on"

	defaultCacheRoutingTTL             = 10 * time.Minute
	defaultCacheRoutingMaxHolders      = 4
	defaultCacheRoutingMaxDiscountMs   = 1000.0
	defaultCacheRoutingMaxCostFraction = 0.35
	defaultCacheRoutingActivationPct   = 100.0
	defaultCacheRoutingMaxPlanQPS      = 0.0
	maxCacheRoutingPlanQPS             = 1_000_000.0
	cacheRoutingAttemptTTL             = 2 * time.Minute
	cacheRoutingInFlightAttemptTTL     = 2 * time.Hour
	cacheRoutingSweepInterval          = 30 * time.Second
	cacheRoutingMaxEntries             = 10_000
	cacheRoutingMaxAttempts            = 50_000
	cacheRoutingMaxReceiptTokens       = 1_000_000
	cacheRoutingMaxStageMs             = 10 * 60 * 1000.0
)

type CachePlan struct {
	ModelAggregateHash string
	PromptContractID   string
	CacheScope         string
	PromptTokenCount   int
	Boundaries         []protocol.PrefixCacheAnchor
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
	return pr != nil && pr.cacheRoutingParticipates.Load()
}

func (pr *PendingRequest) setCacheRoutingParticipates(participates bool) {
	if pr != nil {
		pr.cacheRoutingParticipates.Store(participates)
	}
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
	UpdatedAt               time.Time
	ExpiresAt               time.Time
}

type cacheAttempt struct {
	RequestID          string
	ProviderID         string
	Provider           *Provider
	Model              string
	ExpiresAt          time.Time
	CreatedAt          time.Time
	LookupSeen         bool
	V2                 bool
	Plan               CachePlan
	V2Capability       protocol.PrefixCacheV2Capability
	ExpectedPrompt     protocol.PrefixCacheAnchor
	ExpectedBoundaries map[int]string
	LastReadyAnchor    protocol.PrefixCacheAnchor
}

type cacheV2SequenceKey struct {
	ProviderID string
	ModelID    string
	CacheEpoch string
}

type cacheV2ProviderModelKey struct {
	ProviderID string
	ModelID    string
}

type cacheRoutingHint struct {
	PrefillTokensSaved int
	CachedTokens       int
	StageMs            float64
	Provider           *Provider
	Capability         protocol.PrefixCacheV2Capability
	CapabilityRevision uint64
}

type cacheRoutingCapability struct {
	Provider           *Provider
	Capability         protocol.PrefixCacheV2Capability
	CapabilityRevision uint64
}

type cacheHolderRemovalReason string

const (
	cacheHolderRemovalTTL              cacheHolderRemovalReason = "ttl"
	cacheHolderRemovalDisconnect       cacheHolderRemovalReason = "disconnect"
	cacheHolderRemovalEpochChange      cacheHolderRemovalReason = "epoch_change"
	cacheHolderRemovalCapabilityChange cacheHolderRemovalReason = "capability_change"
	cacheHolderRemovalMissInvalidation cacheHolderRemovalReason = "miss_invalidation"
	cacheHolderRemovalCapacityEviction cacheHolderRemovalReason = "capacity_eviction"
)

func CacheHolderRemovalReasons() []string {
	return []string{
		string(cacheHolderRemovalTTL),
		string(cacheHolderRemovalDisconnect),
		string(cacheHolderRemovalEpochChange),
		string(cacheHolderRemovalCapabilityChange),
		string(cacheHolderRemovalMissInvalidation),
		string(cacheHolderRemovalCapacityEviction),
	}
}

type cacheAttemptOrderEntry struct {
	nonce     string
	createdAt time.Time
	index     int
}

type cacheAttemptOrderHeap []*cacheAttemptOrderEntry

func (h cacheAttemptOrderHeap) Len() int { return len(h) }

func (h cacheAttemptOrderHeap) Less(i, j int) bool {
	if h[i].createdAt.Equal(h[j].createdAt) {
		return h[i].nonce < h[j].nonce
	}
	return h[i].createdAt.Before(h[j].createdAt)
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
	updatedAt time.Time
	index     int
}

type cacheHolderOrderHeap []*cacheHolderOrderEntry

func (h cacheHolderOrderHeap) Len() int { return len(h) }

func (h cacheHolderOrderHeap) Less(i, j int) bool {
	if !h[i].updatedAt.Equal(h[j].updatedAt) {
		return h[i].updatedAt.Before(h[j].updatedAt)
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
	mu                  sync.Mutex
	ttl                 time.Duration
	maxHolders          int
	maxEntries          int
	maxAttempts         int
	holderCount         int
	lastSweep           time.Time
	holders             map[string]map[string]cacheHolder
	attempts            map[string]cacheAttempt
	holderOrder         cacheHolderOrderHeap
	holderOrderByRef    map[cacheHolderRef]*cacheHolderOrderEntry
	attemptOrder        cacheAttemptOrderHeap
	attemptOrderByNonce map[string]*cacheAttemptOrderEntry
	v2Sequences         map[cacheV2SequenceKey]uint64
	rejectedV2          map[cacheV2ProviderModelKey]protocol.PrefixCacheV2Capability
	ssdLookups          uint64
	ssdHits             uint64
	ssdMisses           uint64
	ssdDonations        uint64
	holderAdded         uint64
	holderRemoved       map[string]uint64
	donationOutcomes    map[string]uint64
}

func newCacheRoutingTracker(ttl time.Duration, maxHolders int) *cacheRoutingTracker {
	if ttl <= 0 {
		ttl = defaultCacheRoutingTTL
	}
	if maxHolders <= 0 {
		maxHolders = defaultCacheRoutingMaxHolders
	}
	return &cacheRoutingTracker{
		ttl: ttl, maxHolders: maxHolders, maxEntries: cacheRoutingMaxEntries, maxAttempts: cacheRoutingMaxAttempts,
		holders: make(map[string]map[string]cacheHolder), attempts: make(map[string]cacheAttempt),
		holderOrderByRef: make(map[cacheHolderRef]*cacheHolderOrderEntry), attemptOrderByNonce: make(map[string]*cacheAttemptOrderEntry),
		v2Sequences:      make(map[cacheV2SequenceKey]uint64),
		rejectedV2:       make(map[cacheV2ProviderModelKey]protocol.PrefixCacheV2Capability),
		holderRemoved:    make(map[string]uint64),
		donationOutcomes: make(map[string]uint64),
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
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	tracker.sweepIfDueLocked(time.Now())
	return tracker.holderCount, len(tracker.attempts)
}

type CacheRoutingLifecycleStatus struct {
	SSDLookups       uint64            `json:"ssd_lookups"`
	SSDHits          uint64            `json:"ssd_hits"`
	SSDMisses        uint64            `json:"ssd_misses"`
	SSDDonations     uint64            `json:"ssd_donations"`
	HolderAdded      uint64            `json:"holder_added"`
	HolderRemoved    map[string]uint64 `json:"holder_removed"`
	DonationOutcomes map[string]uint64 `json:"donation_outcomes"`
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
	// Build the zero-filled vocabularies before taking the tracker lock, which
	// sits on the cache-routing dispatch path.
	holderRemoved := zeroBuckets[uint64](CacheHolderRemovalReasons())
	donationOutcomes := zeroBuckets[uint64](prefixCacheDonationOutcomes)
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	for reason, count := range tracker.holderRemoved {
		holderRemoved[reason] = count
	}
	for outcome, count := range tracker.donationOutcomes {
		donationOutcomes[outcome] = count
	}
	return CacheRoutingLifecycleStatus{
		SSDLookups: tracker.ssdLookups, SSDHits: tracker.ssdHits,
		SSDMisses: tracker.ssdMisses, SSDDonations: tracker.ssdDonations,
		HolderAdded: tracker.holderAdded, HolderRemoved: holderRemoved,
		DonationOutcomes: donationOutcomes,
	}
}

// recordDonationOutcomes folds donation-counter deltas into the central
// aggregates, saturating at MaxUint64. The caller (UpdatePrefixCacheSnapshot)
// only produces positive deltas for vocabulary outcomes that already passed
// sanitizePrefixCacheDonationOutcomes, so no re-validation happens under the
// routing-path lock.
func (t *cacheRoutingTracker) recordDonationOutcomes(deltas map[string]uint64) {
	if t == nil || len(deltas) == 0 {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for outcome, delta := range deltas {
		current := t.donationOutcomes[outcome]
		if delta > math.MaxUint64-current {
			t.donationOutcomes[outcome] = math.MaxUint64
		} else {
			t.donationOutcomes[outcome] = current + delta
		}
	}
}
