package registry_test

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// One tracker generation as the registry constructed it: the kernel it
// serializes, the indexes and byte ledger it charges, and its maintainer.
type budgetLifecycleTracker struct {
	core        *cachetracker.Tracker[*production.Provider]
	config      cachetracker.Config[*production.Provider]
	maintenance production.CacheMaintainer
}

// budgetLifecycleFixture retains the actual components of every generation.
// Sequential tests read them directly, as the registry's receipt controller
// would under its own mutex; no second registry state exists.
type budgetLifecycleFixture struct {
	*production.Registry
	plans preparationFixture
	clock *fenceTestClock
	mu    sync.Mutex
	// Constructor inputs of the next generation. A zero byte limit keeps the
	// registry's own default ledger; kernel adjusts the config a kernel accepts.
	maxBytes uint64
	kernel   func(*cachetracker.Config[*production.Provider])
	trackers []*budgetLifecycleTracker
	revision *cachepeer.Revision
}

func (f *budgetLifecycleFixture) tracker() *budgetLifecycleTracker {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.trackers[len(f.trackers)-1]
}

func (f *budgetLifecycleFixture) setMaxBytes(maxBytes uint64) {
	f.mu.Lock()
	f.maxBytes = maxBytes
	f.mu.Unlock()
}

func budgetLifecycleRegistry(t *testing.T, setup ...func(*budgetLifecycleFixture, *production.CacheDependencies)) (*budgetLifecycleFixture, *production.Provider, protocol.PrefixCacheV2Capability) {
	t.Helper()
	f := &budgetLifecycleFixture{clock: &fenceTestClock{now: time.Now()}}
	var deps production.CacheDependencies
	for _, apply := range setup {
		apply(f, &deps)
	}
	deps.Now = f.clock.Now
	deps.AttemptBudgets = func() *cachetracker.AttemptBudget {
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.maxBytes == 0 {
			return nil
		}
		return cachetracker.NewAttemptBudget(f.maxBytes)
	}
	deps.Trackers = func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.kernel != nil {
			f.kernel(&config)
		}
		tracker := &budgetLifecycleTracker{core: cachetracker.New(config), config: config}
		f.trackers = append(f.trackers, tracker)
		f.plans.mu.Lock()
		f.plans.generation = config.Generation
		f.plans.mu.Unlock()
		return tracker.core
	}
	deps.Maintenance = func(owner production.CacheMaintenance) production.CacheMaintainer {
		f.mu.Lock()
		f.trackers[len(f.trackers)-1].maintenance = owner
		f.mu.Unlock()
		return owner
	}
	deps.Revisions = func(string) *cachepeer.Revision {
		revision := cachepeer.NewRevision()
		f.mu.Lock()
		f.revision = revision
		f.mu.Unlock()
		return revision
	}
	r, _, capability := exactTestRegistry(t, production.Dependencies{Cache: deps})
	f.Registry = r
	// Replace the fixture connection by one that registers its model inventory
	// and a checkpoint-mode capability through the real registration path.
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	r.Disconnect("provider-a")
	provider := r.Register("provider-a", nil, &protocol.RegisterMessage{
		Models:              []protocol.ModelInfo{{ID: "model", WeightHash: capability.ModelAggregateHash}},
		PrefixCacheProtocol: 2, PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
	})
	return f, provider, capability
}

func budgetLifecycleRequest(r *budgetLifecycleFixture, id string) *production.PendingRequest {
	return &production.PendingRequest{RequestID: id, Model: "model", EstimatedPromptTokens: 4096,
		CachePlan: r.plans.bind(exactTestPlan(exactTestAnchor(16, "c")))}
}

// The published owner is observed through its immutable receipt metadata.
func budgetLifecyclePrepare(t *testing.T, r *budgetLifecycleFixture, provider *production.Provider, request *production.PendingRequest) protocol.InferenceRequestMessage {
	t.Helper()
	if err := r.PrepareCacheAttempt(request, provider); err != nil {
		t.Fatal(err)
	}
	owner := preparedTestCacheMetadata(request)
	if owner.CacheReceiptNonce == "" || !request.CacheRoutingParticipates() {
		t.Fatal("fixture did not prepare an admitted cache attempt")
	}
	return owner
}

// This checks conservation of stored immutable charges, independently of the
// production charging function. Formula correctness belongs to the unit suite.
// Returning errors lets concurrent callers report without Fatal in a goroutine.
// Callers must not run it while a registry operation is inside the tracker.
func budgetLifecycleInvariant(tracker *budgetLifecycleTracker) (int, uint64, error) {
	config := tracker.config
	ledger, limit := config.AttemptBudget.Bytes(), config.AttemptBudget.MaxBytes()
	count := config.Attempts.Len()
	if count != config.AttemptOrder.Len() || count != config.AttemptOrder.KeyCount() || count > config.MaxAttempts {
		return count, ledger, fmt.Errorf("attempt map/heap/count cap mismatch")
	}
	heap := make([]*cacheindex.Entry[cacheindex.AttemptRef], config.AttemptOrder.Len())
	for index, entry := range config.AttemptOrder.Entries() {
		heap[index] = entry
	}
	var sum uint64
	for nonce, attempt := range config.Attempts.Entries() {
		if attempt.AccountedBytes == 0 || attempt.AccountedBytes > ^uint64(0)-sum {
			return count, ledger, fmt.Errorf("zero or overflowing stored charge")
		}
		sum += attempt.AccountedBytes
		entry := config.AttemptOrder.Load(nonce)
		if entry == nil || entry.Key().Nonce != nonce || entry.Position() < 0 || entry.Position() >= len(heap) || heap[entry.Position()] != entry {
			return count, ledger, fmt.Errorf("attempt heap ownership mismatch")
		}
		if entry.Key().ProviderID != attempt.ProviderID || !entry.ExpiresAt().Equal(attempt.ExpiresAt) {
			return count, ledger, fmt.Errorf("attempt expiry/provider index metadata mismatch")
		}
		if !config.AttemptProviders.Contains(attempt.ProviderID, entry) {
			return count, ledger, fmt.Errorf("attempt missing from provider index")
		}
	}
	if sum != ledger || sum > limit {
		return count, ledger, fmt.Errorf("retained charge sum=%d ledger=%d limit=%d", sum, ledger, limit)
	}
	return count, sum, nil
}

func budgetLifecycleWant(t *testing.T, tracker *budgetLifecycleTracker, count int) uint64 {
	t.Helper()
	got, bytes, err := budgetLifecycleInvariant(tracker)
	if err != nil || got != count {
		t.Fatalf("attempts=%d want=%d bytes=%d invariant=%v", got, count, bytes, err)
	}
	return bytes
}
