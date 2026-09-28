package registry

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// persistenceTestProvider registers a provider the way the wire path does:
// the provider exists first, then its capabilities are applied through
// UpdatePrefixCacheCapabilities, which is where restored holders bind.
func persistenceTestProvider(t *testing.T, r *Registry, id string, capability protocol.PrefixCacheV2Capability) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r, id, "model", 100)
	p.mu.Lock()
	p.PrefillTPS = 100
	p.PrefixCacheProtocol = 2
	p.Models[0].WeightHash = capability.ModelAggregateHash
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
	p.mu.Unlock()
	if err := r.UpdatePrefixCacheCapabilities(id, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
		t.Fatalf("apply capabilities for %s: %v", id, err)
	}
	return p
}

func startPersistence(t *testing.T, r *Registry, st store.Store) CacheRoutingPersistenceStatus {
	t.Helper()
	r.SetStore(st)
	status, err := r.StartCacheRoutingPersistence(context.Background())
	if err != nil {
		t.Fatalf("start persistence: %v", err)
	}
	if !status.Enabled {
		t.Fatal("persistence did not enable on a memory store")
	}
	return status
}

func storedHolders(t *testing.T, st store.CacheRoutingStateStore) []store.CacheHolderRecord {
	t.Helper()
	rows, err := st.LoadCacheHolders(context.Background(), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func TestCacheRoutingPersistenceSurvivesRestart(t *testing.T) {
	t.Run("memory", func(t *testing.T) { testCacheRoutingPersistenceSurvivesRestart(t, store.NewMemory(store.Config{})) })
	t.Run("postgres", func(t *testing.T) {
		dbURL := os.Getenv("DATABASE_URL")
		if dbURL == "" {
			t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		pg, err := store.NewPostgres(ctx, store.Config{DatabaseURL: dbURL})
		if err != nil {
			t.Fatalf("NewPostgres: %v", err)
		}
		far := time.Now().Add(1000 * time.Hour)
		if _, err := pg.PruneCacheRoutingState(ctx, far, far); err != nil {
			t.Fatalf("clear: %v", err)
		}
		testCacheRoutingPersistenceSurvivesRestart(t, pg)
	})
}

func testCacheRoutingPersistenceSurvivesRestart(t *testing.T, st store.Store) {
	t.Helper()
	cacheStore, ok := store.As[store.CacheRoutingStateStore](st)
	if !ok {
		t.Fatal("store cannot persist cache routing state")
	}
	r1, _, capability := exactTestRegistry(t)
	removeTestProvider(r1, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r1, st)
	a := persistenceTestProvider(t, r1, "machine-a", capability)

	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := boundTestCachePlan(r1, exactTestPlan(checkpoint, floor))
	_, ready := checkpointTestAttempt(t, r1, a, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r1.ApplyPrefixCacheReadyV2(a.ID, ready) {
		t.Fatal("ready receipt rejected")
	}
	if hints := memoryTestHints(r1, plan, time.Now()); len(hints) != 1 || hints[a.ID].Tier != "ssd" {
		t.Fatalf("live holder missing before restart: %+v", hints)
	}
	// Demand observed through the plan path is marked and flushed too.
	r1.mu.RLock()
	routeKey := append([]byte(nil), r1.cacheRouteKeys.route...)
	tracker1 := r1.cacheRouting
	r1.mu.RUnlock()
	observed := plan
	tracker1.observeCacheDemand(&observed, routeKey, time.Now())
	tracker1.observeCacheDemand(&observed, routeKey, time.Now())
	if observed.RepeatedPrefixTokens <= 0 {
		t.Fatal("second observation should report repeated demand")
	}
	if err := r1.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows := storedHolders(t, cacheStore)
	if len(rows) != 1 || rows[0].CacheEpoch != capability.CacheEpoch || rows[0].Tier != "ssd" ||
		rows[0].AnchorTokenCount != checkpoint.TokenCount || rows[0].ModelID != "model" {
		t.Fatalf("durable holder row wrong: %+v", rows)
	}
	demand, _ := cacheStore.LoadCacheDemand(context.Background(), time.Now().Add(-time.Minute))
	if len(demand) == 0 {
		t.Fatal("demand keys were not persisted")
	}
	s1 := r1.CacheRoutingPersistenceStatus()
	if s1.RowsWritten == 0 || s1.Flushes == 0 || s1.FlushErrors != 0 {
		t.Fatalf("persistence counters wrong: %+v", s1)
	}

	// --- restart: a fresh registry on the same store, same master key ---
	r2, _, _ := exactTestRegistry(t)
	removeTestProvider(r2, "provider-a")
	status := startPersistence(t, r2, st)
	if status.PendingHolders != 1 || status.RestoredDemand == 0 {
		t.Fatalf("restore did not park the holder and demand: %+v", status)
	}
	plan2 := boundTestCachePlan(r2, exactTestPlan(checkpoint, floor))
	if hints := memoryTestHints(r2, plan2, time.Now()); len(hints) != 0 {
		t.Fatalf("parked holder must not be routable before its provider returns: %+v", hints)
	}
	// Demand came back without any new observation.
	r2.mu.RLock()
	tracker2 := r2.cacheRouting
	r2.mu.RUnlock()
	restoredPlan := plan2
	tracker2.observeCacheDemand(&restoredPlan, routeKey, time.Now())
	if restoredPlan.RepeatedPrefixTokens <= 0 {
		t.Fatal("restored demand index did not report the repeated prefix")
	}
	// A provider with a different epoch does not claim the row.
	other := capability
	other.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	persistenceTestProvider(t, r2, "machine-other", other)
	if hints := memoryTestHints(r2, plan2, time.Now()); len(hints) != 0 {
		t.Fatalf("holder bound to a provider with a different epoch: %+v", hints)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.PendingHolders != 1 {
		t.Fatalf("row consumed by the wrong epoch: %+v", s)
	}
	// The same machine reconnects under a new provider ID with its old epoch.
	back := persistenceTestProvider(t, r2, "machine-a-reconnected", capability)
	hints := memoryTestHints(r2, plan2, time.Now())
	if len(hints) != 1 || hints[back.ID].Tier != "ssd" || hints[back.ID].CachedTokens != checkpoint.TokenCount {
		t.Fatalf("restored holder not bound to the reconnected provider: %+v", hints)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.BoundHolders != 1 || s.PendingHolders != 0 {
		t.Fatalf("bind counters wrong: %+v", s)
	}
	repeat := &PendingRequest{RequestID: "after-restart", Model: "model", CachePlan: plan2,
		EstimatedPromptTokens: plan2.PromptTokenCount, RequestedMaxTokens: 128}
	selected, decision := r2.ReserveProviderEx("model", repeat)
	if selected != back || decision.CacheDiscountMs <= 0 {
		t.Fatalf("routing did not credit the restored holder: provider=%v decision=%+v", selected, decision)
	}
	selected.RemovePending(repeat.RequestID)
	r2.SetProviderIdle(selected.ID)

	// --- second restart inside the TTL: no duplicate rows, binding still works ---
	if err := r2.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, cacheStore); len(rows) != 1 {
		t.Fatalf("rebinding must not duplicate rows: %d", len(rows))
	}
	r3, _, _ := exactTestRegistry(t)
	removeTestProvider(r3, "provider-a")
	if s := startPersistence(t, r3, st); s.PendingHolders != 1 {
		t.Fatalf("second restart restore: %+v", s)
	}
	again := persistenceTestProvider(t, r3, "machine-a-third", capability)
	plan3 := boundTestCachePlan(r3, exactTestPlan(checkpoint, floor))
	if hints := memoryTestHints(r3, plan3, time.Now()); len(hints) != 1 || hints[again.ID].Tier != "ssd" {
		t.Fatalf("holder lost on the second restart: %+v", hints)
	}
}

func TestCacheRoutingPersistenceRemovalSemantics(t *testing.T) {
	st := store.NewMemory(store.Config{})
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	a := persistenceTestProvider(t, r, "machine-a", capability)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))
	_, ready := checkpointTestAttempt(t, r, a, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(a.ID, ready) {
		t.Fatal("ready receipt rejected")
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(storedHolders(t, st)) != 1 {
		t.Fatal("holder not persisted")
	}
	// A disconnect drops the live holder but keeps the durable row.
	r.cacheRouting.disconnect(a.ID, cacheHolderRemovalDisconnect)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(storedHolders(t, st)) != 1 {
		t.Fatal("disconnect must keep the durable row")
	}
	// The same provider reconnecting re-binds it.
	removeTestProvider(r, a.ID)
	back := persistenceTestProvider(t, r, "machine-a-back", capability)
	if hints := memoryTestHints(r, plan, time.Now()); len(hints) != 1 || hints[back.ID].Tier != "ssd" {
		t.Fatalf("row not rebound after disconnect: %+v", hints)
	}
	// A capability change is a real invalidation: the row goes away.
	r.cacheRouting.invalidateProviderEvidence(back.ID, cacheHolderRemovalCapabilityChange, true)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 0 {
		t.Fatalf("capability change must delete the durable row: %+v", rows)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.RowsDeleted != 1 {
		t.Fatalf("delete counter wrong: %+v", s)
	}
}

func TestCacheRoutingPersistenceOffWithoutStore(t *testing.T) {
	r, p, capability := exactTestRegistry(t)
	status, err := r.StartCacheRoutingPersistence(context.Background())
	if err != nil || status.Enabled {
		t.Fatalf("no store must mean no persistence: %+v %v", status, err)
	}
	// Hooks are nil-safe: receipts still work with no persister attached.
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	p.mu.Lock()
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	p.mu.Unlock()
	plan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))
	_, ready := checkpointTestAttempt(t, r, p, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("ready receipt rejected without persistence")
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatalf("flush without persister must be a no-op: %v", err)
	}
	if got := r.CacheRoutingLifecycleStatus().Persistence; got.Enabled {
		t.Fatalf("status must report persistence off: %+v", got)
	}
}

// flakyCacheStore fails every write while broken is set.
type flakyCacheStore struct {
	store.CacheRoutingStateStore
	broken bool
}

func (f *flakyCacheStore) UpsertCacheHolders(ctx context.Context, r []store.CacheHolderRecord) error {
	if f.broken {
		return errors.New("store down")
	}
	return f.CacheRoutingStateStore.UpsertCacheHolders(ctx, r)
}

func (f *flakyCacheStore) UpsertCacheDemand(ctx context.Context, r []store.CacheDemandRecord) error {
	if f.broken {
		return errors.New("store down")
	}
	return f.CacheRoutingStateStore.UpsertCacheDemand(ctx, r)
}

func TestCacheRoutingPersisterRetriesAndDedupesDemand(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	flaky := &flakyCacheStore{CacheRoutingStateStore: mem, broken: true}
	p := newCacheRoutingPersister(flaky, testLogger())
	now := time.Now()
	holder := cacheHolder{ProviderID: "p", ModelID: "model", CacheEpoch: "e", Tier: "ssd",
		Anchor: protocol.PrefixCacheAnchor{ChainHash: "h", TokenCount: 1024}, StageMs: 50,
		UpdatedAt: now, ExpiresAt: now.Add(time.Minute)}
	p.markHolderUpsert("key-1", holder)
	p.markDemand([]string{"d-1", "d-2"}, now)
	if err := p.flush(context.Background()); err == nil {
		t.Fatal("flush must report the store failure")
	}
	if s := p.status(); s.FlushErrors != 1 || s.RowsWritten != 0 {
		t.Fatalf("failure counters: %+v", s)
	}
	flaky.broken = false
	if err := p.flush(context.Background()); err != nil {
		t.Fatalf("retry flush: %v", err)
	}
	if rows, _ := mem.LoadCacheHolders(context.Background(), now); len(rows) != 1 {
		t.Fatalf("requeued holder not written: %d", len(rows))
	}
	if d, _ := mem.LoadCacheDemand(context.Background(), now.Add(-time.Minute)); len(d) != 2 {
		t.Fatalf("requeued demand not written: %d", len(d))
	}
	// Within the granularity window the same key is not written again.
	p.markDemand([]string{"d-1"}, now.Add(10*time.Second))
	if batch := p.drain(); len(batch.demand) != 0 {
		t.Fatalf("demand key re-marked inside the granularity window: %+v", batch.demand)
	}
	p.markDemand([]string{"d-1"}, now.Add(2*time.Minute))
	if batch := p.drain(); len(batch.demand) != 1 {
		t.Fatalf("demand key not re-marked after the window: %+v", batch.demand)
	}
	// Memory-tier holders never reach the store.
	p.markHolderUpsert("memory:key", cacheHolder{ProviderID: "p", ModelID: "model", CacheEpoch: "e", Tier: "memory",
		UpdatedAt: now, ExpiresAt: now.Add(time.Second)})
	if batch := p.drain(); len(batch.upserts) != 0 {
		t.Fatalf("memory-tier holder marked for persistence: %+v", batch.upserts)
	}
}
