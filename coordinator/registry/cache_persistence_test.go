package registry

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
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
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	status, err := r.StartCacheRoutingPersistence(ctx)
	if err != nil {
		t.Fatalf("start persistence: %v", err)
	}
	if !status.Enabled {
		t.Fatal("persistence did not enable on a memory store")
	}
	return status
}

func storedHolders(t *testing.T, st crs.Store) []crs.HolderRecord {
	t.Helper()
	rows, err := st.LoadCacheHolders(context.Background(), time.Now(), 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func TestCacheRoutingPersistenceSurvivesRestart(t *testing.T) {
	t.Run("memory", func(t *testing.T) { testCacheRoutingPersistenceSurvivesRestart(t, store.NewMemory(store.Config{})) })
	t.Run("postgres", func(t *testing.T) {
		testCacheRoutingPersistenceSurvivesRestart(t, isolatedPostgresStore(t))
	})
}

// isolatedPostgresStore opens a throwaway database created from DATABASE_URL,
// so this package's row-count assertions never collide with the store
// package's contract test, which runs concurrently in CI against the shared
// database. The database is dropped on cleanup.
func isolatedPostgresStore(t *testing.T) store.Store {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set — skipping PostgreSQL integration test")
	}
	parsed, err := url.Parse(dbURL)
	if err != nil {
		t.Fatalf("parse DATABASE_URL: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	name := fmt.Sprintf("cachepersist_%d_%d", time.Now().UnixNano(), os.Getpid())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		admin.Close(ctx)
		t.Fatalf("create database: %v", err)
	}
	isolated := *parsed
	isolated.Path = "/" + name
	pg, err := store.NewPostgres(ctx, store.Config{DatabaseURL: isolated.String()})
	if err != nil {
		_, _ = admin.Exec(ctx, "DROP DATABASE "+name+" WITH (FORCE)")
		admin.Close(ctx)
		t.Fatalf("NewPostgres: %v", err)
	}
	t.Cleanup(func() {
		pg.Close()
		dropCtx, dropCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer dropCancel()
		_, _ = admin.Exec(dropCtx, "DROP DATABASE "+name+" WITH (FORCE)")
		admin.Close(dropCtx)
	})
	return pg
}

func testCacheRoutingPersistenceSurvivesRestart(t *testing.T, st store.Store) {
	t.Helper()
	cacheStore, ok := store.As[crs.Store](st)
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
	demand, _ := cacheStore.LoadCacheDemand(context.Background(), time.Now().Add(-time.Minute), time.Now(), 0)
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

// The wire order: capabilities arrive inside the RegisterMessage, and the
// heartbeat that follows re-applies the same set, so nothing "changes". A
// restored holder must bind on that path, not only on a capability change.
func TestCacheRoutingPersistenceBindsOnWireRegistration(t *testing.T) {
	st := store.NewMemory(store.Config{})
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
	if err := r1.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}

	r2, _, _ := exactTestRegistry(t)
	removeTestProvider(r2, "provider-a")
	startPersistence(t, r2, st)
	// A capability for another model under the same epoch must not consume
	// the parked rows.
	otherModel := capability
	otherModel.ModelID = "model-b"
	r2.Register("other-model", nil, &protocol.RegisterMessage{
		Models:              []protocol.ModelInfo{{ID: "model-b", WeightHash: capability.ModelAggregateHash}},
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{otherModel},
	})
	if s := r2.CacheRoutingPersistenceStatus(); s.PendingHolders != 1 || s.BoundHolders != 0 {
		t.Fatalf("another model's capability consumed the parked row: %+v", s)
	}
	wire := r2.Register("machine-a-wire", nil, &protocol.RegisterMessage{
		Models:              []protocol.ModelInfo{{ID: "model", WeightHash: capability.ModelAggregateHash}},
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
	})
	plan2 := boundTestCachePlan(r2, exactTestPlan(checkpoint, floor))
	hints := memoryTestHints(r2, plan2, time.Now())
	if len(hints) != 1 || hints[wire.ID].Tier != "ssd" {
		t.Fatalf("holder did not bind on registration with capabilities in the message: %+v", hints)
	}
	// The unchanged heartbeat re-apply must be harmless.
	if err := r2.UpdatePrefixCacheCapabilities(wire.ID, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
		t.Fatal(err)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.BoundHolders != 1 || s.PendingHolders != 0 {
		t.Fatalf("bind counters after wire registration: %+v", s)
	}
}

// A capability change on a provider drops the rows parked for its previous
// capability instead of re-binding stale evidence, and deletes them durably.
func TestCacheRoutingPersistenceCapabilityChangeDropsParkedRows(t *testing.T) {
	st := store.NewMemory(store.Config{})
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))
	a := persistenceTestProvider(t, r, "session-1", capability)
	_, ready := checkpointTestAttempt(t, r, a, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(a.ID, ready) {
		t.Fatal("ready receipt rejected")
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	r.cacheRouting.disconnect(a.ID, cacheHolderRemovalDisconnect)
	removeTestProvider(r, a.ID)
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 1 {
		t.Fatalf("disconnect must park the row: %+v", s)
	}
	// Same machine returns, then its contract changes before any receipt.
	b := persistenceTestProvider(t, r, "session-2", capability)
	if hints := memoryTestHints(r, plan, time.Now()); len(hints) != 1 || hints[b.ID].Tier != "ssd" {
		t.Fatalf("row not rebound on return: %+v", hints)
	}
	r.cacheRouting.disconnect(b.ID, cacheHolderRemovalDisconnect)
	removeTestProvider(r, b.ID)
	c := persistenceTestProvider(t, r, "session-3", capability)
	changed := capability
	changed.PromptContractID = strings.Repeat("e", 64)
	c.mu.Lock()
	c.Models[0].WeightHash = changed.ModelAggregateHash
	c.mu.Unlock()
	// The row bound on session-3's registration; now the contract changes.
	if err := r.UpdatePrefixCacheCapabilities(c.ID, 2, []protocol.PrefixCacheV2Capability{changed}); err != nil {
		t.Fatal(err)
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 0 {
		t.Fatalf("capability change must delete the durable row: %+v", rows)
	}
	if hints := memoryTestHints(r, plan, time.Now()); len(hints) != 0 {
		t.Fatalf("stale evidence survived a capability change: %+v", hints)
	}
	// And a row parked while the capability changes is dropped, not rebound.
	r.cacheRouting.disconnect(c.ID, cacheHolderRemovalDisconnect)
	removeTestProvider(r, c.ID)
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 {
		t.Fatalf("nothing should be parked after invalidation: %+v", s)
	}
}

// A new session can take fresh receipts before the old session's rows are
// parked; binding the parked rows must not roll the live holder back.
func TestCacheRoutingPersistenceParkedRowNeverOverwritesNewerLiveHolder(t *testing.T) {
	st := store.NewMemory(store.Config{})
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))

	old := persistenceTestProvider(t, r, "session-1", capability)
	_, ready := checkpointTestAttempt(t, r, old, capability, "donor-1", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(old.ID, ready) {
		t.Fatal("first receipt rejected")
	}
	time.Sleep(2 * time.Millisecond)
	fresh := persistenceTestProvider(t, r, "session-2", capability)
	_, ready2 := checkpointTestAttempt(t, r, fresh, capability, "donor-2", plan, 1)
	ready2.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready2.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(fresh.ID, ready2) {
		t.Fatal("second receipt rejected")
	}
	var key string
	var liveUpdated time.Time
	r.cacheRouting.mu.Lock()
	for k, holders := range r.cacheRouting.holders {
		if h, ok := holders[fresh.ID]; ok {
			key, liveUpdated = k, h.UpdatedAt
		}
	}
	r.cacheRouting.mu.Unlock()
	if key == "" {
		t.Fatal("fresh session holder missing")
	}
	// Old session leaves: its row is parked, then the fresh session re-applies
	// unchanged capabilities and the parked row is offered to it.
	r.cacheRouting.disconnect(old.ID, cacheHolderRemovalDisconnect)
	removeTestProvider(r, old.ID)
	if err := r.UpdatePrefixCacheCapabilities(fresh.ID, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
		t.Fatal(err)
	}
	r.cacheRouting.mu.Lock()
	h := r.cacheRouting.holders[key][fresh.ID]
	r.cacheRouting.mu.Unlock()
	if !h.UpdatedAt.Equal(liveUpdated) || h.Provider != fresh {
		t.Fatalf("parked row rolled back the live holder: got %v want %v", h.UpdatedAt, liveUpdated)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 {
		t.Fatalf("parked row not consumed: %+v", s)
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 || !rows[0].UpdatedAt.Equal(liveUpdated) {
		t.Fatalf("durable row must carry the newer receipt: %+v", rows)
	}
}

// The registry decides what is persistable: resident (memory-tier) holders
// never reach the store.
func TestCacheRoutingPersistenceSkipsMemoryTier(t *testing.T) {
	st := store.NewMemory(store.Config{})
	r, _, capability := exactTestRegistry(t)
	startPersistence(t, r, st)
	now := time.Now()
	r.cacheRouting.mu.Lock()
	r.cacheRouting.persistHolderUpsert("memory:key", cacheHolder{ProviderID: "p", ModelID: "model", CacheEpoch: capability.CacheEpoch,
		Tier: "memory", UpdatedAt: now, ExpiresAt: now.Add(time.Second)})
	r.cacheRouting.persistHolderUpsert("ssd-key", cacheHolder{ProviderID: "p", ModelID: "model", CacheEpoch: capability.CacheEpoch,
		Tier: "ssd", Anchor: protocol.PrefixCacheAnchor{ChainHash: "h", TokenCount: 1024}, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute)})
	r.cacheRouting.mu.Unlock()
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows := storedHolders(t, st)
	if len(rows) != 1 || rows[0].Key != "ssd-key" {
		t.Fatalf("only the SSD holder may be persisted: %+v", rows)
	}
}

// A restored row whose provider returns with the same epoch and model but a
// different prompt contract is deleted durably at bind, not reloaded and
// rejected again on every boot.
func TestCacheRoutingPersistenceDeletesMismatchedRestoredRows(t *testing.T) {
	st := store.NewMemory(store.Config{})
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
	if err := r1.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 {
		t.Fatalf("expected one durable row: %+v", rows)
	}

	r2, _, _ := exactTestRegistry(t)
	removeTestProvider(r2, "provider-a")
	if s := startPersistence(t, r2, st); s.PendingHolders != 1 {
		t.Fatalf("restore did not park the row: %+v", s)
	}
	changed := capability
	changed.PromptContractID = strings.Repeat("e", 64)
	persistenceTestProvider(t, r2, "machine-a-back", changed)
	plan2 := boundTestCachePlan(r2, exactTestPlan(checkpoint, floor))
	if hints := memoryTestHints(r2, plan2, time.Now()); len(hints) != 0 {
		t.Fatalf("mismatched row must not become a live holder: %+v", hints)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 || s.BoundHolders != 0 || s.DroppedPending != 1 {
		t.Fatalf("mismatched row must be taken and dropped: %+v", s)
	}
	if err := r2.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 0 {
		t.Fatalf("mismatched row must be deleted durably: %+v", rows)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.RowsDeleted != 1 {
		t.Fatalf("delete not counted: %+v", s)
	}
	// A third boot has nothing to reload for that provider.
	r3, _, _ := exactTestRegistry(t)
	removeTestProvider(r3, "provider-a")
	if s := startPersistence(t, r3, st); s.PendingHolders != 0 || s.RestoredHolders != 0 {
		t.Fatalf("deleted row came back: %+v", s)
	}
}

// Two overlapping sessions of one machine share one durable row (same key and
// epoch). Invalidating the older session's holder must not delete the row that
// is now the newer session's evidence.
func TestCacheRoutingPersistenceKeepsRowOwnedByOtherLiveSession(t *testing.T) {
	st := store.NewMemory(store.Config{})
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))
	first := persistenceTestProvider(t, r, "session-1", capability)
	second := persistenceTestProvider(t, r, "session-2", capability)
	for i, p := range []*Provider{first, second} {
		_, ready := checkpointTestAttempt(t, r, p, capability, fmt.Sprintf("donor-%d", i), plan, 1)
		ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
		ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
		if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
			t.Fatalf("receipt for %s rejected", p.ID)
		}
	}
	if hints := memoryTestHints(r, plan, time.Now()); len(hints) != 2 {
		t.Fatalf("both sessions should hold the boundary: %+v", hints)
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 {
		t.Fatalf("both sessions share one durable row: %+v", rows)
	}
	// The older session's evidence is invalidated for a non-disconnect reason.
	r.cacheRouting.invalidateProviderEvidence(first.ID, cacheHolderRemovalCapabilityChange, true)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 || rows[0].CacheEpoch != capability.CacheEpoch {
		t.Fatalf("row owned by the live second session was deleted: %+v", rows)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.RowsDeleted != 0 {
		t.Fatalf("no delete should have been issued: %+v", s)
	}
	if hints := memoryTestHints(r, plan, time.Now()); len(hints) != 1 || hints[second.ID].Tier != "ssd" {
		t.Fatalf("second session's holder lost: %+v", hints)
	}
	// Once the last session's evidence goes too, the row is deleted.
	r.cacheRouting.invalidateProviderEvidence(second.ID, cacheHolderRemovalCapabilityChange, true)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 0 {
		t.Fatalf("row must be deleted once no live session holds it: %+v", rows)
	}
}

// A parked row from another block-hash generation (a coordinator upgrade
// bumped promptcontract.BlockHashVersion while the provider's epoch stayed)
// is rejected at bind without deleting the row the same session holds live.
func TestCacheRoutingPersistenceMismatchAtBindKeepsLiveRow(t *testing.T) {
	st := store.NewMemory(store.Config{})
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))
	a := persistenceTestProvider(t, r, "session-1", capability)
	_, ready := checkpointTestAttempt(t, r, a, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(a.ID, ready) {
		t.Fatal("ready receipt rejected")
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows := storedHolders(t, st)
	if len(rows) != 1 {
		t.Fatalf("expected one durable row: %+v", rows)
	}
	// The same row as an older generation would have restored and parked it.
	legacy := rows[0]
	legacy.BlockHashVersion = "legacy-v0"
	legacy.UpdatedAt = legacy.UpdatedAt.Add(-time.Second)
	r.cacheRouting.persister.Park(legacy)
	// The next heartbeat re-applies the same capabilities and takes the row.
	if err := r.UpdatePrefixCacheCapabilities(a.ID, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
		t.Fatal(err)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 || s.DroppedPending != 1 {
		t.Fatalf("legacy row must be taken and dropped: %+v", s)
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 || rows[0].BlockHashVersion != capability.BlockHashVersion {
		t.Fatalf("the live session's row must survive the mismatched parked row: %+v", rows)
	}
	if hints := memoryTestHints(r, plan, time.Now()); len(hints) != 1 || hints[a.ID].Tier != "ssd" {
		t.Fatalf("live holder lost: %+v", hints)
	}
}

// A capability change drops the rows parked for the old capability, but a
// parked row that a live session of the same machine still holds is that
// session's evidence and must survive.
func TestCacheRoutingPersistenceCapabilityChangeKeepsRowOwnedByLiveSession(t *testing.T) {
	st := store.NewMemory(store.Config{})
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))
	// Three overlapping sessions of one machine (same epoch); the third has
	// no evidence of its own.
	live := persistenceTestProvider(t, r, "session-live", capability)
	gone := persistenceTestProvider(t, r, "session-gone", capability)
	changer := persistenceTestProvider(t, r, "session-changer", capability)
	for i, p := range []*Provider{live, gone} {
		_, ready := checkpointTestAttempt(t, r, p, capability, fmt.Sprintf("donor-%d", i), plan, 1)
		ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
		ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
		if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
			t.Fatalf("receipt for %s rejected", p.ID)
		}
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 {
		t.Fatalf("both sessions share one durable row: %+v", rows)
	}
	// One session disconnects: its row is parked while the other still holds
	// the boundary live.
	r.cacheRouting.disconnect(gone.ID, cacheHolderRemovalDisconnect)
	removeTestProvider(r, gone.ID)
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 1 {
		t.Fatalf("disconnect must park the row: %+v", s)
	}
	// The third session's contract changes: the parked row is dropped, but
	// the durable row is still the live session's evidence.
	changed := capability
	changed.PromptContractID = strings.Repeat("e", 64)
	if err := r.UpdatePrefixCacheCapabilities(changer.ID, 2, []protocol.PrefixCacheV2Capability{changed}); err != nil {
		t.Fatal(err)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 || s.DroppedPending != 1 {
		t.Fatalf("parked row must be dropped: %+v", s)
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 || rows[0].CacheEpoch != capability.CacheEpoch {
		t.Fatalf("row owned by the live session was deleted by the capability change: %+v", rows)
	}
	if hints := memoryTestHints(r, plan, time.Now()); len(hints) != 1 || hints[live.ID].Tier != "ssd" {
		t.Fatalf("live session's holder lost: %+v", hints)
	}
	// With the live session gone too, the same change deletes the row.
	r.cacheRouting.invalidateProviderEvidence(live.ID, cacheHolderRemovalCapabilityChange, true)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 0 {
		t.Fatalf("row must be deleted once no live session holds it: %+v", rows)
	}
}

// A lookup's measured stage cost outranks the Ready fallback until its own
// deadline. The durable row carries it, so a restart inside that window keeps
// routing on the measured value instead of flipping to the estimate.
func TestCacheRoutingPersistenceRestoresMeasuredStage(t *testing.T) {
	st := store.NewMemory(store.Config{})
	r1, _, capability := exactTestRegistry(t)
	removeTestProvider(r1, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r1, st)
	a := persistenceTestProvider(t, r1, "machine-a", capability)
	checkpoint := exactTestAnchor(16, "c")
	plan := boundTestCachePlan(r1, exactTestPlan(checkpoint))
	now := time.Now()
	const measured, estimate = 900.0, 50.0
	// A measured SSD hit, then a Ready refresh with a different fallback.
	pr := &PendingRequest{RequestID: "reader", Model: "model", CachePlan: plan}
	if err := prepareBoundTestCacheAttempt(r1, pr, a); err != nil {
		t.Fatal(err)
	}
	nonce := preparedTestCacheMetadata(pr).CacheReceiptNonce
	lookup := testV2Lookup(nonce, capability, plan.Boundaries[len(plan.Boundaries)-1], 1)
	lookup.RequestID, lookup.Outcome, lookup.StageMs = "reader", "hit", measured
	lookup.MatchedAnchor = &checkpoint
	lookup.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if accepted, mismatch := r1.cacheRouting.applyLookupV2Result(a.ID, a, capability, lookup, r1.cacheRouteKeys.route, now); !accepted || mismatch {
		t.Fatalf("lookup accepted=%v mismatch=%v", accepted, mismatch)
	}
	ready := testV2Ready(nonce, capability, checkpoint, 2)
	ready.RequestID, ready.StageMs = "reader", estimate
	if accepted, mismatch := r1.cacheRouting.applyReadyV2Result(a.ID, a, capability, ready, r1.cacheRouteKeys.route, now); !accepted || mismatch {
		t.Fatalf("ready accepted=%v mismatch=%v", accepted, mismatch)
	}
	if hints := memoryTestHints(r1, plan, now); len(hints) != 1 || hints[a.ID].StageMs != measured {
		t.Fatalf("measured stage must outrank the Ready fallback before the restart: %+v", hints)
	}
	if err := r1.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows := storedHolders(t, st)
	if len(rows) != 1 || rows[0].StageMs != estimate || rows[0].MeasuredStageMs != measured || !rows[0].MeasuredExpiresAt.After(now) {
		t.Fatalf("row must carry both the fallback and the measurement: %+v", rows)
	}

	r2, _, _ := exactTestRegistry(t)
	removeTestProvider(r2, "provider-a")
	startPersistence(t, r2, st)
	back := persistenceTestProvider(t, r2, "machine-a-back", capability)
	plan2 := boundTestCachePlan(r2, exactTestPlan(checkpoint))
	hints := memoryTestHints(r2, plan2, now)
	if len(hints) != 1 || hints[back.ID].StageMs != measured {
		t.Fatalf("restart flipped routing back to the Ready estimate: %+v", hints)
	}
	// The measurement is bound to the capability the row bound to and keeps
	// its own deadline: past it, the fallback applies again.
	r2.cacheRouting.mu.Lock()
	var bound cacheHolder
	for _, h := range r2.cacheRouting.holders[cacheTierBoundaryKey(r2.cacheRouteKeys.route, plan2, checkpoint, "ssd")] {
		bound = h
	}
	r2.cacheRouting.mu.Unlock()
	if bound.stageMeasurement == nil || bound.stageMeasurement.capability != hints[back.ID].Capability ||
		bound.stageMeasurement.expiresAt.After(bound.ExpiresAt) {
		t.Fatalf("restored measurement not bound to the live capability within the holder's life: %+v", bound.stageMeasurement)
	}
	if got := bound.stageCostAt(bound.stageMeasurement.expiresAt); got != estimate {
		t.Fatalf("fallback must apply once the measurement expires: got %v", got)
	}
}

// The demand index reports which restored entries it accepted; only those
// count as already persisted, so a key the index rejected (at the TTL edge
// here) is written again on its next observation.
func TestCacheDemandRestoreReportsAcceptedEntries(t *testing.T) {
	r, _, _ := exactTestRegistry(t)
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	now := time.Now()
	ttl := tracker.demand.ttl
	accepted := tracker.demand.restore([]crs.DemandRecord{
		{Key: "fresh", SeenAt: now.Add(-time.Second)},
		{Key: "edge", SeenAt: now.Add(-ttl)},
		{Key: "future", SeenAt: now.Add(time.Second)},
		{Key: "", SeenAt: now},
	}, now)
	if len(accepted) != 1 || accepted[0].Key != "fresh" {
		t.Fatalf("only the entry inside the window is accepted: %+v", accepted)
	}
	entries, _ := tracker.demand.stats()
	if entries != 1 {
		t.Fatalf("index holds %d entries, want 1", entries)
	}
}

// fingerprintFlakyStore fails the key-generation read while fail is set, the
// way a busy database at boot does.
type fingerprintFlakyStore struct {
	*store.MemoryStore
	fail atomic.Bool
}

func (f *fingerprintFlakyStore) CacheRoutingKeyFingerprint(ctx context.Context) (string, error) {
	if f.fail.Load() {
		return "", errors.New("store down")
	}
	return f.MemoryStore.CacheRoutingKeyFingerprint(ctx)
}

// A boot whose restore fails before the key generation is recorded writes
// nothing (the next boot would reset such rows as foreign) until a retried
// restore succeeds; then the run's evidence is flushed under the generation.
func TestCacheRoutingPersistenceRetriesRestoreBeforeWriting(t *testing.T) {
	st := &fingerprintFlakyStore{MemoryStore: store.NewMemory(store.Config{})}
	st.fail.Store(true)
	r, _, capability := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	r.SetStore(st)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	status, err := r.StartCacheRoutingPersistence(ctx)
	if err == nil || !status.Enabled || status.Ready {
		t.Fatalf("boot restore must fail and leave the persister not ready: err=%v %+v", err, status)
	}
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
	if rows := storedHolders(t, st); len(rows) != 0 {
		t.Fatalf("nothing may be written before the key generation is recorded: %+v", rows)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.RowsWritten != 0 || s.Flushes != 0 {
		t.Fatalf("flush must be a no-op while not ready: %+v", s)
	}
	// The store recovers; the loop's retry (driven directly here) restores,
	// records the generation and unblocks writes.
	st.fail.Store(false)
	r.mu.RLock()
	tracker, persister := r.cacheRouting, r.cachePersister
	r.mu.RUnlock()
	if err := r.restoreCacheRoutingState(ctx, persister, tracker); err != nil {
		t.Fatalf("retried restore: %v", err)
	}
	if s := r.CacheRoutingPersistenceStatus(); !s.Ready || s.KeyRotated {
		t.Fatalf("retried restore must mark the persister ready: %+v", s)
	}
	r.mu.RLock()
	want := r.cacheRouteKeys.persistFingerprint
	r.mu.RUnlock()
	if fp, _ := st.CacheRoutingKeyFingerprint(context.Background()); fp != want {
		t.Fatalf("generation not recorded: %q want %q", fp, want)
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 {
		t.Fatalf("evidence gathered before the retry must be written after it: %+v", rows)
	}
	if hints := memoryTestHints(r, plan, time.Now()); len(hints) != 1 || hints[a.ID].Tier != "ssd" {
		t.Fatalf("live holder lost across the retry: %+v", hints)
	}
}

// With three overlapping sessions sharing a row, losing one must leave the
// row reflecting the newest surviving evidence, not an arbitrary survivor.
// Repeated because map order is random.
func TestCacheRoutingPersistenceKeepsNewestSurvivingHolder(t *testing.T) {
	for round := 0; round < 6; round++ {
		st := store.NewMemory(store.Config{})
		r, _, capability := exactTestRegistry(t)
		removeTestProvider(r, "provider-a")
		capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
		// In the past: a load skips rows updated after its clock.
		base := time.Now().Add(-10 * time.Second).Truncate(time.Second)
		clock := base
		r.SetCacheRoutingClockForTest(func() time.Time { return clock })
		startPersistence(t, r, st)
		checkpoint := exactTestAnchor(16, "c")
		floor := exactTestAnchor(17, "d")
		plan := boundTestCachePlan(r, exactTestPlan(checkpoint, floor))
		var sessions []*Provider
		for i := 0; i < 3; i++ {
			clock = base.Add(time.Duration(i) * time.Second)
			p := persistenceTestProvider(t, r, fmt.Sprintf("session-%d", i), capability)
			_, ready := checkpointTestAttempt(t, r, p, capability, fmt.Sprintf("donor-%d", i), plan, 1)
			ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
			ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
			ready.StageMs = float64(100 * (i + 1))
			if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
				t.Fatalf("receipt %d rejected", i)
			}
			sessions = append(sessions, p)
		}
		if err := r.FlushCacheRoutingState(context.Background()); err != nil {
			t.Fatal(err)
		}
		// The oldest session's evidence goes; two survive with different ages.
		r.cacheRouting.invalidateProviderEvidence(sessions[0].ID, cacheHolderRemovalCapabilityChange, true)
		if err := r.FlushCacheRoutingState(context.Background()); err != nil {
			t.Fatal(err)
		}
		rows := storedHolders(t, st)
		if len(rows) != 1 || !rows[0].UpdatedAt.Equal(base.Add(2*time.Second)) || rows[0].StageMs != 300 {
			t.Fatalf("round %d: row must carry the newest survivor's evidence: %+v", round, rows)
		}
	}
}

// The persistence fingerprint pins the master key together with every key
// derivation label and the block contract. If this golden value changes, the
// next deploy resets the durable copy: expected when a derivation changes,
// and this test makes that a deliberate step rather than a surprise.
func TestPersistFingerprintPinsDerivationInputs(t *testing.T) {
	keys := deriveCacheKeys([]byte("0123456789abcdef0123456789abcdef"))
	const want = "0293c846684bd74755e82740"
	if keys.persistFingerprint != want {
		t.Fatalf("persistence fingerprint changed: got %s want %s (a derivation label, the block contract or the persistence generation moved; the durable copy resets on deploy)", keys.persistFingerprint, want)
	}
	if other := deriveCacheKeys([]byte("fedcba9876543210fedcba9876543210")); other.persistFingerprint == keys.persistFingerprint {
		t.Fatal("fingerprint must depend on the master key")
	}
}
