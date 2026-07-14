package registry

import (
	"sync"
	"time"
)

const (
	CacheRoutingOff          = "off"
	CacheRoutingObserve      = "observe"
	CacheRoutingExact        = "exact"
	CacheRoutingConversation = "conversation"

	defaultCacheRoutingTTL             = 10 * time.Minute
	defaultCacheRoutingMaxHolders      = 4
	defaultCacheRoutingMaxDiscountMs   = 1000.0
	defaultCacheRoutingMaxCostFraction = 0.35
	cacheRoutingAttemptTTL             = 2 * time.Minute
	cacheRoutingInFlightAttemptTTL     = 2 * time.Hour
	cacheRoutingCapacitySuppression    = 15 * time.Second
	cacheRoutingSweepInterval          = 30 * time.Second
	cacheRoutingMaxEntries             = 10_000
	cacheRoutingMaxAttempts            = 50_000
	// Each attempt can carry both an exact and conversation route key. Keeping
	// two watermarks per live attempt prevents cap eviction from reopening a
	// delayed-receipt resurrection window while remaining strictly bounded.
	cacheRoutingMaxWatermarks    = 2 * cacheRoutingMaxAttempts
	cacheRoutingMaxReceiptTokens = 1_000_000
	cacheRoutingMaxStageMs       = 10 * 60 * 1000.0
	// Older protocol-v1 providers omit stage_ms on durable SSD-ready receipts.
	// Treat that cost as unknown and maximally conservative until a measured hit
	// replaces it, rather than granting SSD evidence a zero-cost discount.
	cacheRoutingUnmeasuredSSDStageMs = cacheRoutingMaxStageMs
)

type CacheRoute struct {
	ExactKey         string
	ConversationKey  string
	ConversationKind string
	ScopeNamespace   string
}

func (r CacheRoute) present() bool {
	return r.ExactKey != "" || r.ConversationKey != ""
}

// CacheRoutingParticipates reports whether this request was derived while a
// cache rollout mode was enabled. Callers use it only to suppress feedback that
// assumes a full prefill; route keys themselves remain registry-private.
func (pr *PendingRequest) CacheRoutingParticipates() bool {
	return pr != nil && pr.CacheRoute.present()
}

type cacheRouteKeys struct {
	route []byte
	scope []byte
}

type cacheHolder struct {
	ProviderID              string
	EvidenceSequence        uint64
	ReadyTokens             int
	RequiredRecomputeTokens int
	PrefillTokensSaved      int
	CachedTokens            int
	StageMs                 float64
	Tier                    string
	Outcome                 string
	Confirmed               bool
	SuppressedUntil         time.Time
	UpdatedAt               time.Time
	ExpiresAt               time.Time
}

type cacheAttempt struct {
	RequestID       string
	ProviderID      string
	Model           string
	Sequence        uint64
	ExactKey        string
	ConversationKey string
	ExpiresAt       time.Time
	CreatedAt       time.Time
	LookupSeen      bool
	ReadyTokens     int
}

type cacheRoutingHint struct {
	Kind               string
	Confidence         float64
	PrefillTokensSaved int
	CachedTokens       int
	ReadyTokens        int
	RecomputeTokens    int
	StageMs            float64
	Tier               string
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

type cacheEvidenceWatermark struct {
	Sequence  uint64
	UpdatedAt time.Time
	ExpiresAt time.Time
}

type cacheWatermarkOrderEntry struct {
	ref       cacheHolderRef
	updatedAt time.Time
	index     int
}

type cacheWatermarkOrderHeap []*cacheWatermarkOrderEntry

func (h cacheWatermarkOrderHeap) Len() int { return len(h) }
func (h cacheWatermarkOrderHeap) Less(i, j int) bool {
	if !h[i].updatedAt.Equal(h[j].updatedAt) {
		return h[i].updatedAt.Before(h[j].updatedAt)
	}
	if h[i].ref.key != h[j].ref.key {
		return h[i].ref.key < h[j].ref.key
	}
	return h[i].ref.providerID < h[j].ref.providerID
}
func (h cacheWatermarkOrderHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
	h[i].index = i
	h[j].index = j
}
func (h *cacheWatermarkOrderHeap) Push(value any) {
	entry := value.(*cacheWatermarkOrderEntry)
	entry.index = len(*h)
	*h = append(*h, entry)
}
func (h *cacheWatermarkOrderHeap) Pop() any {
	old := *h
	last := len(old) - 1
	entry := old[last]
	old[last] = nil
	entry.index = -1
	*h = old[:last]
	return entry
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
	maxWatermarks       int
	holderCount         int
	lastSweep           time.Time
	holders             map[string]map[string]cacheHolder
	attempts            map[string]cacheAttempt
	holderOrder         cacheHolderOrderHeap
	holderOrderByRef    map[cacheHolderRef]*cacheHolderOrderEntry
	attemptOrder        cacheAttemptOrderHeap
	attemptOrderByNonce map[string]*cacheAttemptOrderEntry
	watermarks          map[cacheHolderRef]cacheEvidenceWatermark
	watermarkOrder      cacheWatermarkOrderHeap
	watermarkOrderByRef map[cacheHolderRef]*cacheWatermarkOrderEntry
	activeAttemptRefs   map[cacheHolderRef]*cacheActiveAttemptRefState
	nextAttemptSequence uint64
}

func newCacheRoutingTracker(ttl time.Duration, maxHolders int) *cacheRoutingTracker {
	if ttl <= 0 {
		ttl = defaultCacheRoutingTTL
	}
	if maxHolders <= 0 {
		maxHolders = defaultCacheRoutingMaxHolders
	}
	return &cacheRoutingTracker{
		ttl: ttl, maxHolders: maxHolders, maxEntries: cacheRoutingMaxEntries, maxAttempts: cacheRoutingMaxAttempts, maxWatermarks: cacheRoutingMaxWatermarks,
		holders: make(map[string]map[string]cacheHolder), attempts: make(map[string]cacheAttempt),
		holderOrderByRef: make(map[cacheHolderRef]*cacheHolderOrderEntry), attemptOrderByNonce: make(map[string]*cacheAttemptOrderEntry),
		watermarks: make(map[cacheHolderRef]cacheEvidenceWatermark), watermarkOrderByRef: make(map[cacheHolderRef]*cacheWatermarkOrderEntry),
		activeAttemptRefs: make(map[cacheHolderRef]*cacheActiveAttemptRefState),
	}
}
