package cachedirectory

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/cacheattempt"
)

// Directory owns one receipt and holder transaction domain. Its mutex, maps,
// proof fences and eviction indexes are private. Connection is the caller's
// exact comparable connection identity; operations never call back into it.
type Directory[C comparable] struct {
	generation           *cacheattempt.Generation
	mu                   sync.Mutex
	ttl                  time.Duration
	maxHolders           int
	maxEntries           int
	maxAttempts          int
	holderCount          int
	lastSweep            time.Time
	holders              map[string]map[string]Holder[C]
	attempts             map[string]Attempt[C]
	holderOrder          cacheHolderOrderHeap
	holderOrderByRef     map[cacheHolderRef]*cacheHolderOrderEntry
	attemptOrder         cacheAttemptOrderHeap
	attemptOrderByNonce  map[string]*cacheAttemptOrderEntry
	v2Sequences          map[cacheV2SequenceKey]uint64
	rejectedV2           map[cacheV2ProviderModelKey]protocol.PrefixCacheV2Capability
	ssdLookups           uint64
	ssdHits              uint64
	ssdMisses            uint64
	ssdDonations         uint64
	holderAdded          uint64
	holderRemoved        map[string]uint64
	donationOutcomes     map[string]uint64
	donationOutcomeNames []string
}

func New[C comparable](generation *cacheattempt.Generation, ttl time.Duration, maxHolders int, donationOutcomes []string) *Directory[C] {
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	if maxHolders <= 0 {
		maxHolders = DefaultMaxHolders
	}
	return &Directory[C]{
		generation: generation,
		ttl:        ttl, maxHolders: maxHolders, maxEntries: MaxEntries, maxAttempts: MaxAttempts,
		holders: make(map[string]map[string]Holder[C]), attempts: make(map[string]Attempt[C]),
		holderOrderByRef: make(map[cacheHolderRef]*cacheHolderOrderEntry), attemptOrderByNonce: make(map[string]*cacheAttemptOrderEntry),
		v2Sequences:          make(map[cacheV2SequenceKey]uint64),
		rejectedV2:           make(map[cacheV2ProviderModelKey]protocol.PrefixCacheV2Capability),
		holderRemoved:        make(map[string]uint64),
		donationOutcomes:     make(map[string]uint64),
		donationOutcomeNames: append([]string(nil), donationOutcomes...),
	}
}

func zeroConnection[C comparable]() C { var zero C; return zero }

// RegisterAttempt installs the authenticated attempt before request publication.
// The caller releases this operation before rechecking live registry ownership.
// Plan boundaries and expected proofs are immutable after registration.
func (t *Directory[C]) RegisterAttempt(nonce string, attempt Attempt[C]) {
	t.mu.Lock()
	t.storeAttemptLocked(nonce, attempt)
	if len(t.attempts) > t.maxAttempts {
		t.enforceAttemptCapLocked()
	}
	t.mu.Unlock()
}

type Config struct {
	TTL        time.Duration
	MaxHolders int
}

func (t *Directory[C]) Config() Config { return Config{TTL: t.ttl, MaxHolders: t.maxHolders} }
