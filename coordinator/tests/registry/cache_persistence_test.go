package registry_test

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

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/store/postgres"
)

// persistenceTestProvider registers a provider the way the wire path does:
// the provider exists first, then its capabilities are applied through
// UpdatePrefixCacheCapabilities, which is where restored holders bind.
func persistenceTestProvider(t *testing.T, r *persistenceFixture, id string, capability protocol.PrefixCacheV2Capability) *production.Provider {
	t.Helper()
	p := makeSchedulerProvider(t, r.Registry, id, "model", 100)
	p.Mu().Lock()
	p.PrefillTPS = 100
	p.PrefixCacheProtocol = 2
	p.Models[0].WeightHash = capability.ModelAggregateHash
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 100
	p.Mu().Unlock()
	if err := r.UpdatePrefixCacheCapabilities(id, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
		t.Fatalf("apply capabilities for %s: %v", id, err)
	}
	return p
}

func startPersistence(t *testing.T, r *persistenceFixture, st store.Store) production.CacheRoutingPersistenceStatus {
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
	t.Run("memory", func(t *testing.T) { testCacheRoutingPersistenceSurvivesRestart(t, memory.NewMemory(store.Config{})) })
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
	pg, err := postgres.NewPostgres(ctx, store.Config{DatabaseURL: isolated.String()})
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
	r1, _, capability := newPersistenceFixture(t)
	r1.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r1, st)
	a := persistenceTestProvider(t, r1, "machine-a", capability)

	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r1, exactTestPlan(checkpoint, floor))
	_, ready := persistenceAttempt(t, r1, a, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r1.ApplyPrefixCacheReadyV2(a.ID, ready) {
		t.Fatal("ready receipt rejected")
	}
	if hints := persistenceHints(r1, plan, time.Now()); len(hints) != 1 || hints[a.ID].Tier != "ssd" {
		t.Fatalf("live holder missing before restart: %+v", hints)
	}
	// Demand observed through the plan path is marked and flushed too.
	routeKey := append([]byte(nil), r1.routeKey...)
	observed := plan
	observed.ObserveRouteDemand(r1.config.Generation, r1.demand, routeKey, time.Now(), 0)
	observed.ObserveRouteDemand(r1.config.Generation, r1.demand, routeKey, time.Now(), 0)
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
	r2, _, _ := newPersistenceFixture(t)
	r2.Disconnect("provider-a")
	status := startPersistence(t, r2, st)
	if status.PendingHolders != 1 || status.RestoredDemand == 0 {
		t.Fatalf("restore did not park the holder and demand: %+v", status)
	}
	plan2 := persistenceBoundPlan(r2, exactTestPlan(checkpoint, floor))
	if hints := persistenceHints(r2, plan2, time.Now()); len(hints) != 0 {
		t.Fatalf("parked holder must not be routable before its provider returns: %+v", hints)
	}
	// Demand came back without any new observation.
	restoredPlan := plan2
	restoredPlan.ObserveRouteDemand(r2.config.Generation, r2.demand, routeKey, time.Now(), 0)
	if restoredPlan.RepeatedPrefixTokens <= 0 {
		t.Fatal("restored demand index did not report the repeated prefix")
	}
	// A provider with a different epoch does not claim the row.
	other := capability
	other.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	persistenceTestProvider(t, r2, "machine-other", other)
	if hints := persistenceHints(r2, plan2, time.Now()); len(hints) != 0 {
		t.Fatalf("holder bound to a provider with a different epoch: %+v", hints)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.PendingHolders != 1 {
		t.Fatalf("row consumed by the wrong epoch: %+v", s)
	}
	// The same machine reconnects under a new provider ID with its old epoch.
	back := persistenceTestProvider(t, r2, "machine-a-reconnected", capability)
	hints := persistenceHints(r2, plan2, time.Now())
	if len(hints) != 1 || hints[back.ID].Tier != "ssd" || hints[back.ID].CachedTokens != checkpoint.TokenCount {
		t.Fatalf("restored holder not bound to the reconnected provider: %+v", hints)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.BoundHolders != 1 || s.PendingHolders != 0 {
		t.Fatalf("bind counters wrong: %+v", s)
	}
	repeat := &production.PendingRequest{RequestID: "after-restart", Model: "model", CachePlan: plan2,
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
	r3, _, _ := newPersistenceFixture(t)
	r3.Disconnect("provider-a")
	if s := startPersistence(t, r3, st); s.PendingHolders != 1 {
		t.Fatalf("second restart restore: %+v", s)
	}
	again := persistenceTestProvider(t, r3, "machine-a-third", capability)
	plan3 := persistenceBoundPlan(r3, exactTestPlan(checkpoint, floor))
	if hints := persistenceHints(r3, plan3, time.Now()); len(hints) != 1 || hints[again.ID].Tier != "ssd" {
		t.Fatalf("holder lost on the second restart: %+v", hints)
	}
}

func TestCacheRoutingPersistenceRemovalSemantics(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	a := persistenceTestProvider(t, r, "machine-a", capability)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))
	_, ready := persistenceAttempt(t, r, a, capability, "donor", plan, 1)
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
	deletesBefore := r.CacheRoutingPersistenceStatus().RowsDeleted
	// A disconnect drops the live holder but keeps the durable row.
	r.maintenance.InvalidateProviderEvidence(a.ID, cachetracker.RemovalDisconnect, false)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(storedHolders(t, st)) != 1 {
		t.Fatal("disconnect must keep the durable row")
	}
	// The same provider reconnecting re-binds it.
	r.Disconnect(a.ID)
	back := persistenceTestProvider(t, r, "machine-a-back", capability)
	if hints := persistenceHints(r, plan, time.Now()); len(hints) != 1 || hints[back.ID].Tier != "ssd" {
		t.Fatalf("row not rebound after disconnect: %+v", hints)
	}
	// A capability change is a real invalidation: the row goes away.
	r.maintenance.InvalidateProviderEvidence(back.ID, cachetracker.RemovalCapabilityChange, true)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 0 {
		t.Fatalf("capability change must delete the durable row: %+v", rows)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.RowsDeleted != deletesBefore+1 {
		t.Fatalf("delete counter wrong: %+v", s)
	}
}

func TestCacheRoutingPersistenceOffWithoutStore(t *testing.T) {
	r, p, capability := newPersistenceFixture(t)
	status, err := r.StartCacheRoutingPersistence(context.Background())
	if err != nil || status.Enabled {
		t.Fatalf("no store must mean no persistence: %+v %v", status, err)
	}
	// Hooks are nil-safe: receipts still work with no persister attached.
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	p.Mu().Lock()
	p.PrefixCacheV2Models = map[string]protocol.PrefixCacheV2Capability{"model": capability}
	p.Mu().Unlock()
	plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))
	_, ready := persistenceAttempt(t, r, p, capability, "donor", plan, 1)
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
	st := memory.NewMemory(store.Config{})
	r1, _, capability := newPersistenceFixture(t)
	r1.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r1, st)
	a := persistenceTestProvider(t, r1, "machine-a", capability)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r1, exactTestPlan(checkpoint, floor))
	_, ready := persistenceAttempt(t, r1, a, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r1.ApplyPrefixCacheReadyV2(a.ID, ready) {
		t.Fatal("ready receipt rejected")
	}
	if err := r1.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}

	r2, _, _ := newPersistenceFixture(t)
	r2.Disconnect("provider-a")
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
	plan2 := persistenceBoundPlan(r2, exactTestPlan(checkpoint, floor))
	hints := persistenceHints(r2, plan2, time.Now())
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
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))
	a := persistenceTestProvider(t, r, "session-1", capability)
	_, ready := persistenceAttempt(t, r, a, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(a.ID, ready) {
		t.Fatal("ready receipt rejected")
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	r.maintenance.InvalidateProviderEvidence(a.ID, cachetracker.RemovalDisconnect, false)
	r.Disconnect(a.ID)
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 1 {
		t.Fatalf("disconnect must park the row: %+v", s)
	}
	// Same machine returns, then its contract changes before any receipt.
	b := persistenceTestProvider(t, r, "session-2", capability)
	if hints := persistenceHints(r, plan, time.Now()); len(hints) != 1 || hints[b.ID].Tier != "ssd" {
		t.Fatalf("row not rebound on return: %+v", hints)
	}
	r.maintenance.InvalidateProviderEvidence(b.ID, cachetracker.RemovalDisconnect, false)
	r.Disconnect(b.ID)
	c := persistenceTestProvider(t, r, "session-3", capability)
	changed := capability
	changed.PromptContractID = strings.Repeat("e", 64)
	c.Mu().Lock()
	c.Models[0].WeightHash = changed.ModelAggregateHash
	c.Mu().Unlock()
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
	if hints := persistenceHints(r, plan, time.Now()); len(hints) != 0 {
		t.Fatalf("stale evidence survived a capability change: %+v", hints)
	}
	// And a row parked while the capability changes is dropped, not rebound.
	r.maintenance.InvalidateProviderEvidence(c.ID, cachetracker.RemovalDisconnect, false)
	r.Disconnect(c.ID)
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 {
		t.Fatalf("nothing should be parked after invalidation: %+v", s)
	}
}

// A new session can take fresh receipts before the old session's rows are
// parked; binding the parked rows must not roll the live holder back.
func TestCacheRoutingPersistenceParkedRowNeverOverwritesNewerLiveHolder(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))

	old := persistenceTestProvider(t, r, "session-1", capability)
	_, ready := persistenceAttempt(t, r, old, capability, "donor-1", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(old.ID, ready) {
		t.Fatal("first receipt rejected")
	}
	time.Sleep(2 * time.Millisecond)
	fresh := persistenceTestProvider(t, r, "session-2", capability)
	_, ready2 := persistenceAttempt(t, r, fresh, capability, "donor-2", plan, 1)
	ready2.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready2.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r.ApplyPrefixCacheReadyV2(fresh.ID, ready2) {
		t.Fatal("second receipt rejected")
	}
	var key string
	var liveUpdated time.Time
	for k, holders := range r.config.Holders.Buckets() {
		if h, ok := holders.Load(fresh.ID); ok {
			key, liveUpdated = k, h.UpdatedAt
		}
	}
	if key == "" {
		t.Fatal("fresh session holder missing")
	}
	// Old session leaves: its row is parked, then the fresh session re-applies
	// unchanged capabilities and the parked row is offered to it.
	r.maintenance.InvalidateProviderEvidence(old.ID, cachetracker.RemovalDisconnect, false)
	r.Disconnect(old.ID)
	if err := r.UpdatePrefixCacheCapabilities(fresh.ID, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
		t.Fatal(err)
	}
	h := r.config.Holders.Bucket(key).Lookup(fresh.ID)
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
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	startPersistence(t, r, st)
	now := time.Now()
	r.core.PersistHolderUpsert("memory:key", cachetracker.Holder[*production.Provider]{ProviderID: "p", ModelID: "model", CacheEpoch: capability.CacheEpoch,
		Tier: "memory", UpdatedAt: now, ExpiresAt: now.Add(time.Second)})
	r.core.PersistHolderUpsert("ssd-key", cachetracker.Holder[*production.Provider]{ProviderID: "p", ModelID: "model", CacheEpoch: capability.CacheEpoch,
		Tier: "ssd", Anchor: protocol.PrefixCacheAnchor{ChainHash: "h", TokenCount: 1024}, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute)})
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
	st := memory.NewMemory(store.Config{})
	r1, _, capability := newPersistenceFixture(t)
	r1.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r1, st)
	a := persistenceTestProvider(t, r1, "machine-a", capability)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r1, exactTestPlan(checkpoint, floor))
	_, ready := persistenceAttempt(t, r1, a, capability, "donor", plan, 1)
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

	r2, _, _ := newPersistenceFixture(t)
	r2.Disconnect("provider-a")
	if s := startPersistence(t, r2, st); s.PendingHolders != 1 {
		t.Fatalf("restore did not park the row: %+v", s)
	}
	changed := capability
	changed.PromptContractID = strings.Repeat("e", 64)
	persistenceTestProvider(t, r2, "machine-a-back", changed)
	plan2 := persistenceBoundPlan(r2, exactTestPlan(checkpoint, floor))
	if hints := persistenceHints(r2, plan2, time.Now()); len(hints) != 0 {
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
	r3, _, _ := newPersistenceFixture(t)
	r3.Disconnect("provider-a")
	if s := startPersistence(t, r3, st); s.PendingHolders != 0 || s.RestoredHolders != 0 {
		t.Fatalf("deleted row came back: %+v", s)
	}
}

// Two overlapping sessions of one machine share one durable row (same key and
// epoch). Invalidating the older session's holder must not delete the row that
// is now the newer session's evidence.
func TestCacheRoutingPersistenceKeepsRowOwnedByOtherLiveSession(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))
	first := persistenceTestProvider(t, r, "session-1", capability)
	second := persistenceTestProvider(t, r, "session-2", capability)
	for i, p := range []*production.Provider{first, second} {
		_, ready := persistenceAttempt(t, r, p, capability, fmt.Sprintf("donor-%d", i), plan, 1)
		ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
		ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
		if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
			t.Fatalf("receipt for %s rejected", p.ID)
		}
	}
	if hints := persistenceHints(r, plan, time.Now()); len(hints) != 2 {
		t.Fatalf("both sessions should hold the boundary: %+v", hints)
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 {
		t.Fatalf("both sessions share one durable row: %+v", rows)
	}
	deletesBefore := r.CacheRoutingPersistenceStatus().RowsDeleted
	// The older session's evidence is invalidated for a non-disconnect reason.
	r.maintenance.InvalidateProviderEvidence(first.ID, cachetracker.RemovalCapabilityChange, true)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 || rows[0].CacheEpoch != capability.CacheEpoch {
		t.Fatalf("row owned by the live second session was deleted: %+v", rows)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.RowsDeleted != deletesBefore {
		t.Fatalf("invalidating the older session must not issue another delete: %+v", s)
	}
	if hints := persistenceHints(r, plan, time.Now()); len(hints) != 1 || hints[second.ID].Tier != "ssd" {
		t.Fatalf("second session's holder lost: %+v", hints)
	}
	// Once the last session's evidence goes too, the row is deleted.
	r.maintenance.InvalidateProviderEvidence(second.ID, cachetracker.RemovalCapabilityChange, true)
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
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))
	a := persistenceTestProvider(t, r, "session-1", capability)
	_, ready := persistenceAttempt(t, r, a, capability, "donor", plan, 1)
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
	r.persister.Park(legacy)
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
	if hints := persistenceHints(r, plan, time.Now()); len(hints) != 1 || hints[a.ID].Tier != "ssd" {
		t.Fatalf("live holder lost: %+v", hints)
	}
}

// A capability change drops the rows parked for the old capability, but a
// parked row with newer evidence on a live session of the same machine must
// survive as that session's evidence.
func TestCacheRoutingPersistenceCapabilityChangeKeepsRowOwnedByLiveSession(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))
	// Three overlapping sessions of one machine (same epoch); the third has
	// no evidence of its own.
	live := persistenceTestProvider(t, r, "session-live", capability)
	gone := persistenceTestProvider(t, r, "session-gone", capability)
	changer := persistenceTestProvider(t, r, "session-changer", capability)
	for i, p := range []*production.Provider{live, gone} {
		_, ready := persistenceAttempt(t, r, p, capability, fmt.Sprintf("donor-%d", i), plan, 1)
		ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
		ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
		if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
			t.Fatalf("receipt for %s rejected", p.ID)
		}
	}
	// Refresh the surviving session with a hit, not a miss that would
	// invalidate the other session's older, soon-to-be-parked evidence.
	pr := &production.PendingRequest{RequestID: "live-refresh", Model: "model", CachePlan: plan}
	if err := r.PrepareCacheAttempt(pr, live); err != nil {
		t.Fatal(err)
	}
	lookup := fenceTestV2Lookup(pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce, capability, floor, 3)
	lookup.RequestID, lookup.Outcome = pr.RequestID, "hit"
	lookup.MatchedAnchor, lookup.ExpectedPrefillTokensSaved = &checkpoint, checkpoint.TokenCount
	if !r.ApplyPrefixCacheLookupV2(live.ID, lookup) {
		t.Fatal("surviving session's hit rejected")
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 {
		t.Fatalf("both sessions share one durable row: %+v", rows)
	}
	// One session disconnects: its row is parked while the other still holds
	// the boundary live.
	r.maintenance.InvalidateProviderEvidence(gone.ID, cachetracker.RemovalDisconnect, false)
	r.Disconnect(gone.ID)
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
	if hints := persistenceHints(r, plan, time.Now()); len(hints) != 1 || hints[live.ID].Tier != "ssd" {
		t.Fatalf("live session's holder lost: %+v", hints)
	}
	// With the live session gone too, the same change deletes the row.
	r.maintenance.InvalidateProviderEvidence(live.ID, cachetracker.RemovalCapabilityChange, true)
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
	st := memory.NewMemory(store.Config{})
	var clock time.Time
	r1, _, capability := newPersistenceFixture(t, production.CacheDependencies{Now: func() time.Time { return clock }})
	r1.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r1, st)
	a := persistenceTestProvider(t, r1, "machine-a", capability)
	checkpoint := exactTestAnchor(16, "c")
	plan := persistenceBoundPlan(r1, exactTestPlan(checkpoint))
	now := time.Now()
	clock = now
	const measured, estimate = 900.0, 50.0
	// A measured SSD hit, then a Ready refresh with a different fallback.
	pr := &production.PendingRequest{RequestID: "reader", Model: "model", CachePlan: plan}
	if err := r1.PrepareCacheAttempt(pr, a); err != nil {
		t.Fatal(err)
	}
	nonce := pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce
	lookup := fenceTestV2Lookup(nonce, capability, plan.Boundaries[len(plan.Boundaries)-1], 1)
	lookup.RequestID, lookup.Outcome, lookup.StageMs = "reader", "hit", measured
	lookup.MatchedAnchor = &checkpoint
	lookup.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	lookupResult := r1.ApplyPrefixCacheLookupV2Result(a.ID, lookup)
	if accepted, mismatch := lookupResult.Accepted, cacheReceiptMismatch(lookupResult); !accepted || mismatch {
		t.Fatalf("lookup accepted=%v mismatch=%v", accepted, mismatch)
	}
	ready := fenceTestV2Ready(nonce, capability, checkpoint, 2)
	ready.RequestID, ready.StageMs = "reader", estimate
	readyResult := r1.ApplyPrefixCacheReadyV2Result(a.ID, ready)
	if accepted, mismatch := readyResult.Accepted, cacheReceiptMismatch(readyResult); !accepted || mismatch {
		t.Fatalf("ready accepted=%v mismatch=%v", accepted, mismatch)
	}
	if hints := persistenceHints(r1, plan, now); len(hints) != 1 || hints[a.ID].StageMs != measured {
		t.Fatalf("measured stage must outrank the Ready fallback before the restart: %+v", hints)
	}
	if err := r1.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows := storedHolders(t, st)
	if len(rows) != 1 || rows[0].StageMs != estimate || rows[0].MeasuredStageMs != measured || !rows[0].MeasuredExpiresAt.After(now) {
		t.Fatalf("row must carry both the fallback and the measurement: %+v", rows)
	}

	r2, _, _ := newPersistenceFixture(t, production.CacheDependencies{Now: func() time.Time { return clock }})
	r2.Disconnect("provider-a")
	startPersistence(t, r2, st)
	back := persistenceTestProvider(t, r2, "machine-a-back", capability)
	plan2 := persistenceBoundPlan(r2, exactTestPlan(checkpoint))
	hints := persistenceHints(r2, plan2, now)
	if len(hints) != 1 || hints[back.ID].StageMs != measured {
		t.Fatalf("restart flipped routing back to the Ready estimate: %+v", hints)
	}
	// The measurement is bound to the capability the row bound to and keeps
	// its own deadline: past it, the fallback applies again.
	var bound cachetracker.Holder[*production.Provider]
	for _, h := range r2.config.Holders.Entries(cachetracker.CacheTierBoundaryKey(r2.routeKey, plan2, checkpoint, "ssd")) {
		bound = h
	}
	if bound.Measurement == nil || !bound.Measurement.Matches(hints[back.ID].Capability) ||
		bound.Measurement.ExpiresAt().After(bound.ExpiresAt) {
		t.Fatalf("restored measurement not bound to the live capability within the holder's life: %+v", bound.Measurement)
	}
	if got := bound.StageCostAt(bound.Measurement.ExpiresAt()); got != estimate {
		t.Fatalf("fallback must apply once the measurement expires: got %v", got)
	}
	// The row named the boundary by key and token count only (no chain hash
	// at rest), so a Ready refresh on the restored holder must still match
	// it and keep the measurement rather than fall back to the new estimate.
	if bound.Anchor.ChainHash != "" {
		t.Fatalf("restored holder must not carry a chain hash: %+v", bound.Anchor)
	}
	// An attempt whose lookup neither hit nor missed (the provider skipped
	// the read) followed by its Ready: the only Ready that can meet the
	// restored holder without first replacing or invalidating it.
	pr2 := &production.PendingRequest{RequestID: "refresh", Model: "model", CachePlan: plan2}
	if err := r2.PrepareCacheAttempt(pr2, back); err != nil {
		t.Fatal(err)
	}
	nonce2 := pr2.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce
	skipped := fenceTestV2Lookup(nonce2, capability, plan2.Boundaries[len(plan2.Boundaries)-1], 1)
	skipped.RequestID, skipped.Outcome = "refresh", "skipped_capacity"
	skippedResult := r2.ApplyPrefixCacheLookupV2Result(back.ID, skipped)
	if accepted, mismatch := skippedResult.Accepted, cacheReceiptMismatch(skippedResult); !accepted || mismatch {
		t.Fatalf("skipped lookup accepted=%v mismatch=%v", accepted, mismatch)
	}
	refresh := fenceTestV2Ready(nonce2, capability, checkpoint, 2)
	refresh.RequestID, refresh.StageMs = "refresh", 60
	refreshResult := r2.ApplyPrefixCacheReadyV2Result(back.ID, refresh)
	if accepted, mismatch := refreshResult.Accepted, cacheReceiptMismatch(refreshResult); !accepted || mismatch {
		t.Fatalf("refresh accepted=%v mismatch=%v", accepted, mismatch)
	}
	if hints := persistenceHints(r2, plan2, now); len(hints) != 1 || hints[back.ID].StageMs != measured {
		t.Fatalf("Ready refresh after the restart must keep the measured stage: %+v", hints)
	}
}

// fingerprintFlakyStore fails the key-generation read while fail is set, the
// way a busy database at boot does.
type fingerprintFlakyStore struct {
	*memory.MemoryStore
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
	st := &fingerprintFlakyStore{MemoryStore: memory.NewMemory(store.Config{})}
	st.fail.Store(true)
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
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
	plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))
	_, ready := persistenceAttempt(t, r, a, capability, "donor", plan, 1)
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
	if err := r.restoration.Run(ctx); err != nil {
		t.Fatalf("retried restore: %v", err)
	}
	if s := r.CacheRoutingPersistenceStatus(); !s.Ready || s.KeyRotated {
		t.Fatalf("retried restore must mark the persister ready: %+v", s)
	}
	want := r.persistOptions.Fingerprint
	if fp, _ := st.CacheRoutingKeyFingerprint(context.Background()); fp != want {
		t.Fatalf("generation not recorded: %q want %q", fp, want)
	}
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 {
		t.Fatalf("evidence gathered before the retry must be written after it: %+v", rows)
	}
	if hints := persistenceHints(r, plan, time.Now()); len(hints) != 1 || hints[a.ID].Tier != "ssd" {
		t.Fatalf("live holder lost across the retry: %+v", hints)
	}
}

// With three overlapping sessions sharing a row, losing one must leave the
// row reflecting the newest surviving evidence, not an arbitrary survivor.
// Repeated because map order is random.
func TestCacheRoutingPersistenceKeepsNewestSurvivingHolder(t *testing.T) {
	for round := 0; round < 10; round++ {
		st := memory.NewMemory(store.Config{})
		var clock time.Time
		r, _, capability := newPersistenceFixture(t, production.CacheDependencies{Now: func() time.Time { return clock }})
		r.Disconnect("provider-a")
		capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
		// In the past: a load skips rows updated after its clock.
		base := time.Now().Add(-10 * time.Second).Truncate(time.Second)
		clock = base
		startPersistence(t, r, st)
		checkpoint := exactTestAnchor(16, "c")
		floor := exactTestAnchor(17, "d")
		plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))
		var sessions []*production.Provider
		for i := 0; i < 3; i++ {
			clock = base.Add(time.Duration(i)*time.Second - time.Millisecond)
			p := persistenceTestProvider(t, r, fmt.Sprintf("session-%d", i), capability)
			_, ready := persistenceAttempt(t, r, p, capability, fmt.Sprintf("donor-%d", i), plan, 1)
			clock = base.Add(time.Duration(i) * time.Second)
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
		r.maintenance.InvalidateProviderEvidence(sessions[0].ID, cachetracker.RemovalCapabilityChange, true)
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
	keys := persistenceFingerprint(t, []byte("0123456789abcdef0123456789abcdef"))
	const want = "0293c846684bd74755e82740"
	if keys != want {
		t.Fatalf("persistence fingerprint changed: got %s want %s (a derivation label, the block contract or the persistence generation moved; the durable copy resets on deploy)", keys, want)
	}
	if other := persistenceFingerprint(t, []byte("fedcba9876543210fedcba9876543210")); other == keys {
		t.Fatal("fingerprint must depend on the master key")
	}
}

// The bind identity is the full capability contract: a provider back under
// the same epoch, model, artifact, contract and block-hash version but
// another ready-boundary mode does not reclaim rows produced under the old
// mode, exactly as an in-session mode change invalidates them.
func TestCacheRoutingPersistenceModeChangeDropsRestoredRows(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r1, _, capability := newPersistenceFixture(t)
	r1.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r1, st)
	a := persistenceTestProvider(t, r1, "machine-a", capability)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r1, exactTestPlan(checkpoint, floor))
	_, ready := persistenceAttempt(t, r1, a, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r1.ApplyPrefixCacheReadyV2(a.ID, ready) {
		t.Fatal("ready receipt rejected")
	}
	if err := r1.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 || rows[0].ReadyBoundaryMode != protocol.PrefixCacheReadyBoundaryCheckpoint {
		t.Fatalf("row must record the ready-boundary mode: %+v", rows)
	}
	r2, _, _ := newPersistenceFixture(t)
	r2.Disconnect("provider-a")
	if s := startPersistence(t, r2, st); s.PendingHolders != 1 {
		t.Fatalf("restore did not park the row: %+v", s)
	}
	legacy := capability
	legacy.ReadyBoundaryMode = ""
	persistenceTestProvider(t, r2, "machine-a-legacy", legacy)
	plan2 := persistenceBoundPlan(r2, exactTestPlan(checkpoint, floor))
	if hints := persistenceHints(r2, plan2, time.Now()); len(hints) != 0 {
		t.Fatalf("checkpoint evidence must not bind under another ready-boundary mode: %+v", hints)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 || s.BoundHolders != 0 || s.DroppedPending != 1 {
		t.Fatalf("row must be taken and dropped: %+v", s)
	}
	if err := r2.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 0 {
		t.Fatalf("row produced under the old mode must be deleted: %+v", rows)
	}
}

// A holder invalidated in this run while the store was unreachable leaves a
// tombstone queued; a retried restore that still finds the old durable row
// must not resurrect the holder or discard the tombstone.
func TestCacheRoutingPersistenceRetriedRestoreKeepsTombstones(t *testing.T) {
	mem := memory.NewMemory(store.Config{})
	r1, _, capability := newPersistenceFixture(t)
	r1.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r1, mem)
	a := persistenceTestProvider(t, r1, "machine-a", capability)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r1, exactTestPlan(checkpoint, floor))
	_, ready := persistenceAttempt(t, r1, a, capability, "donor", plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r1.ApplyPrefixCacheReadyV2(a.ID, ready) {
		t.Fatal("ready receipt rejected")
	}
	if err := r1.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, mem); len(rows) != 1 {
		t.Fatalf("run 1 must leave one durable row: %+v", rows)
	}

	// Run 2 boots while the store's key-generation read fails.
	st := &fingerprintFlakyStore{MemoryStore: mem}
	st.fail.Store(true)
	r2, _, _ := newPersistenceFixture(t)
	r2.Disconnect("provider-a")
	r2.SetStore(st)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	if _, err := r2.StartCacheRoutingPersistence(ctx); err == nil {
		t.Fatal("boot restore must fail against the broken store")
	}
	back := persistenceTestProvider(t, r2, "machine-a-back", capability)
	plan2 := persistenceBoundPlan(r2, exactTestPlan(checkpoint, floor))
	_, ready2 := persistenceAttempt(t, r2, back, capability, "donor-2", plan2, 1)
	ready2.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
	ready2.ExpectedPrefillTokensSaved = checkpoint.TokenCount
	if !r2.ApplyPrefixCacheReadyV2(back.ID, ready2) {
		t.Fatal("ready receipt rejected")
	}
	// The provider's copy proves bad: the holder goes and its row is tombstoned.
	r2.maintenance.InvalidateProviderEvidence(back.ID, cachetracker.RemovalProofMismatch, true)
	if hints := persistenceHints(r2, plan2, time.Now()); len(hints) != 0 {
		t.Fatalf("invalidated holder still routable: %+v", hints)
	}
	// The provider is away when the store recovers and the retried restore
	// finds run 1's row: the tombstone must keep it out of the pending set,
	// not only out of a bind, because the flush that follows drains the
	// tombstone and a later reconnect would otherwise bind the stale row.
	r2.maintenance.InvalidateProviderEvidence(back.ID, cachetracker.RemovalDisconnect, false)
	r2.Disconnect(back.ID)
	st.fail.Store(false)
	if err := r2.restoration.Run(ctx); err != nil {
		t.Fatalf("retried restore: %v", err)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 || s.DroppedPending != 1 {
		t.Fatalf("the tombstoned row must not be parked: %+v", s)
	}
	if err := r2.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, mem); len(rows) != 0 {
		t.Fatalf("the tombstone must still delete the durable row: %+v", rows)
	}
	again := persistenceTestProvider(t, r2, "machine-a-again", capability)
	if hints := persistenceHints(r2, plan2, time.Now()); len(hints) != 0 {
		t.Fatalf("reconnect after the retried restore resurrected an invalidated holder: %+v", hints)
	}
	if s := r2.CacheRoutingPersistenceStatus(); s.BoundHolders != 0 {
		t.Fatalf("nothing may bind to %s: %+v", again.ID, s)
	}
}

// A bucket larger than one bind chunk binds completely, across several
// tracker-lock holds, at the provider's registration.
func TestCacheRoutingPersistenceBindsLargeBucketInChunks(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	persister := r.persister
	now := time.Now()
	const parked = 2*cachetracker.BindChunkRows + 5
	for i := 0; i < parked; i++ {
		persister.Park(crs.HolderRecord{
			Key: fmt.Sprintf("k%05d", i), CacheEpoch: capability.CacheEpoch, Tier: "ssd", ModelID: "model",
			ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
			BlockHashVersion: capability.BlockHashVersion, ReadyBoundaryMode: capability.ReadyBoundaryMode,
			AnchorTokenCount: 4096, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
		})
	}
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != parked {
		t.Fatalf("parked %d rows, status %+v", parked, s)
	}
	persistenceTestProvider(t, r, "machine-a", capability)
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 || s.BoundHolders != parked {
		t.Fatalf("every parked row must bind at registration, in chunks: %+v", s)
	}
}

// Shutdown joins the persistence loop after cancelling its context.
func TestCacheRoutingPersistenceLoopJoinsOnCancel(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, _ := newPersistenceFixture(t)
	r.SetStore(st)
	ctx, cancel := context.WithCancel(context.Background())
	if _, err := r.StartCacheRoutingPersistence(ctx); err != nil {
		t.Fatal(err)
	}
	waitCtx, waitCancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	if r.WaitCacheRoutingPersistence(waitCtx) {
		t.Fatal("the loop must still be running before its context is cancelled")
	}
	waitCancel()
	cancel()
	joinCtx, joinCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer joinCancel()
	if !r.WaitCacheRoutingPersistence(joinCtx) {
		t.Fatal("the loop must exit once its context is cancelled")
	}
}

// One tracker-lock hold binds at most one chunk across all of a provider's
// capabilities; the rest is reported as remaining for the next hold.
func TestCacheRoutingPersistenceChunkBudgetSpansCapabilities(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	persister := r.persister
	now := time.Now()
	other := capability
	other.ModelID = "model-b"
	for _, c := range []protocol.PrefixCacheV2Capability{capability, other} {
		for i := 0; i < 700; i++ {
			persister.Park(crs.HolderRecord{
				Key: fmt.Sprintf("%s-k%04d", c.ModelID, i), CacheEpoch: c.CacheEpoch, Tier: "ssd", ModelID: c.ModelID,
				ModelAggregateHash: c.ModelAggregateHash, PromptContractID: c.PromptContractID,
				BlockHashVersion: c.BlockHashVersion, ReadyBoundaryMode: c.ReadyBoundaryMode,
				AnchorTokenCount: 4096, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
			})
		}
	}
	p := makeSchedulerProvider(t, r.Registry, "machine-a", "model", 100)
	caps := map[string]protocol.PrefixCacheV2Capability{"model": capability, "model-b": other}
	remaining := r.maintenance.BindChunk(p, caps)
	if s := r.CacheRoutingPersistenceStatus(); !remaining || s.BoundHolders != cachetracker.BindChunkRows || s.PendingHolders != 1400-cachetracker.BindChunkRows {
		t.Fatalf("one hold binds one chunk across capabilities: remaining=%v %+v", remaining, s)
	}
	if remaining = r.maintenance.BindChunk(p, caps); remaining {
		t.Fatal("the second hold must finish the remainder")
	}
	if s := r.CacheRoutingPersistenceStatus(); s.BoundHolders != 1400 || s.PendingHolders != 0 {
		t.Fatalf("every row bound after two holds: %+v", s)
	}
}

// Rows parked for an already-connected session (an older session of the
// same machine was disconnected after this one registered) bind completely
// on the next capability snapshot, the heartbeat path, not one chunk per
// heartbeat.
func TestCacheRoutingPersistenceHeartbeatBindsLargeBucketCompletely(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	p := persistenceTestProvider(t, r, "machine-a", capability)
	persister := r.persister
	now := time.Now()
	const parked = 2*cachetracker.BindChunkRows + 5
	for i := 0; i < parked; i++ {
		persister.Park(crs.HolderRecord{
			Key: fmt.Sprintf("k%05d", i), CacheEpoch: capability.CacheEpoch, Tier: "ssd", ModelID: "model",
			ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
			BlockHashVersion: capability.BlockHashVersion, ReadyBoundaryMode: capability.ReadyBoundaryMode,
			AnchorTokenCount: 4096, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
		})
	}
	// The next heartbeat: the production apply path, capabilities unchanged.
	if _, err := r.UpdatePrefixCacheSnapshot(p.ID, true, 2, []protocol.PrefixCacheV2Capability{capability}, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 || s.BoundHolders != parked {
		t.Fatalf("a heartbeat must bind the whole bucket, in chunks: %+v", s)
	}
}

// A heartbeat that changes only the resident-tier capability of a model
// leaves the rows parked for its unchanged SSD capability alone: they bind
// on that same apply instead of being settled as stale.
func TestCacheRoutingPersistenceMemoryOnlyChangeKeepsParkedRows(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	p := persistenceTestProvider(t, r, "machine-a", capability)
	persister := r.persister
	now := time.Now()
	for i := 0; i < 3; i++ {
		persister.Park(crs.HolderRecord{
			Key: fmt.Sprintf("k%03d", i), CacheEpoch: capability.CacheEpoch, Tier: "ssd", ModelID: "model",
			ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
			BlockHashVersion: capability.BlockHashVersion, ReadyBoundaryMode: capability.ReadyBoundaryMode,
			AnchorTokenCount: 4096, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
		})
	}
	// The resident slot for the model moves to another epoch; the SSD
	// capability is untouched.
	resident := capability
	resident.CacheEpoch = "22222222-2222-2222-2222-222222222222"
	resident.ReadyBoundaryMode = ""
	memory := []protocol.PrefixCacheV2Capability{resident}
	if _, err := r.UpdatePrefixCacheSnapshot(p.ID, false, 0, nil, &memory, nil, nil); err != nil {
		t.Fatal(err)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.DroppedPending != 0 || s.BoundHolders != 3 || s.PendingHolders != 0 {
		t.Fatalf("a resident-only change must not settle parked SSD rows: %+v", s)
	}
}

// A capability change settles a large parked bucket for the old capability
// completely, in chunks outside the apply's locks.
func TestCacheRoutingPersistenceCapabilityChangeSettlesLargeBucket(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	p := persistenceTestProvider(t, r, "machine-a", capability)
	persister := r.persister
	now := time.Now()
	const parked = 2*cachetracker.BindChunkRows + 5
	for i := 0; i < parked; i++ {
		persister.Park(crs.HolderRecord{
			Key: fmt.Sprintf("k%05d", i), CacheEpoch: capability.CacheEpoch, Tier: "ssd", ModelID: "model",
			ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
			BlockHashVersion: capability.BlockHashVersion, ReadyBoundaryMode: capability.ReadyBoundaryMode,
			AnchorTokenCount: 4096, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
		})
	}
	changed := capability
	changed.CacheEpoch = "33333333-3333-3333-3333-333333333333"
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{changed}); err != nil {
		t.Fatal(err)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 || s.DroppedPending != parked || s.BoundHolders != 0 {
		t.Fatalf("every row parked for the old epoch must be settled: %+v", s)
	}
}

// An overflow wakes the persistence loop: the reset lands well inside the
// flush tick rather than at the next one.
func TestCacheRoutingPersistenceOverflowWakesTheLoop(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, _ := newPersistenceFixture(t, production.CacheDependencies{MaxEntries: 8}) // the persister's dirty cap follows: 32
	startPersistence(t, r, st)
	persister := r.persister
	now := time.Now()
	condemned := crs.HolderRecord{
		Key: "condemned", CacheEpoch: "e", Tier: "ssd", ModelID: "model",
		AnchorTokenCount: 1024, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
	}
	persister.MarkHolderUpsert(condemned)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows := storedHolders(t, st); len(rows) != 1 {
		t.Fatalf("the row must be stored before the overflow: %+v", rows)
	}
	// The row's decision is queued first and released by the overflow the
	// fillers cause, so only the reset removes the row.
	persister.MarkHolderDelete(condemned.HolderKey(), now.Add(time.Second))
	for i := 0; i < 32; i++ { // the last one overflows
		persister.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
	}
	deadline := time.Now().Add(3 * time.Second) // the flush tick is 5 s
	for time.Now().Before(deadline) && len(storedHolders(t, st)) != 0 {
		time.Sleep(20 * time.Millisecond)
	}
	if rows := storedHolders(t, st); len(rows) != 0 {
		t.Fatalf("the overflow must wake the loop and reset the durable copy inside the tick: %+v", rows)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.OverflowResets != 1 {
		t.Fatalf("the overflow must be counted: %+v", s)
	}
}

// A capability change that keeps its cache epoch (here the ready-boundary
// mode moves) leaves the bucket to the bind: rows an overlapping session
// parked under the new capability bind, across more than one chunk, and rows
// of the old capability are settled as mismatches at bind rather than swept
// away with them. Parked rows for keys the changing session itself held live
// under the old capability are the exception: unless another live session
// still holds the key under the same epoch, their invalidation is a delete
// decision that outranks the older parked evidence, whatever its identity.
func TestCacheRoutingPersistenceSameEpochChangeBindsNewCapabilityRows(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = "" // the old capability: floor boundaries
	startPersistence(t, r, st)
	p := persistenceTestProvider(t, r, "machine-a", capability)
	persister := r.persister
	now := time.Now()
	changed := capability
	changed.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	park := func(prefix string, n int, mode string) {
		for i := 0; i < n; i++ {
			persister.Park(crs.HolderRecord{
				Key: fmt.Sprintf("%s%05d", prefix, i), CacheEpoch: capability.CacheEpoch, Tier: "ssd", ModelID: "model",
				ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
				BlockHashVersion: capability.BlockHashVersion, ReadyBoundaryMode: mode,
				AnchorTokenCount: 4096, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
			})
		}
	}
	const fresh, stale, overlap = 2*cachetracker.BindChunkRows + 5, 3, 4
	park("n", fresh, changed.ReadyBoundaryMode)    // an overlapping session's evidence under the new capability
	park("o", stale, capability.ReadyBoundaryMode) // evidence of the old capability
	// This session holds the first overlap keys live under the old
	// capability; the change invalidates them.
	for i := 0; i < overlap; i++ {
		r.core.UpsertHolderLocked(fmt.Sprintf("n%05d", i), cachetracker.Holder[*production.Provider]{
			ProviderID: p.ID, Provider: p, ModelID: "model", CacheEpoch: capability.CacheEpoch, Tier: "ssd",
			ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
			BlockHashVersion: capability.BlockHashVersion, ReadyBoundaryMode: capability.ReadyBoundaryMode,
			Anchor: protocol.PrefixCacheAnchor{TokenCount: 4096}, StageMs: 50,
			UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
		})
	}
	if err := r.UpdatePrefixCacheCapabilities(p.ID, 2, []protocol.PrefixCacheV2Capability{changed}); err != nil {
		t.Fatal(err)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.PendingHolders != 0 || s.BoundHolders != fresh-overlap || s.DroppedPending != stale+overlap {
		t.Fatalf("rows under the new capability must bind, the old capability's settle at bind, and the invalidated keys' parked copies drop: %+v", s)
	}
	live := 0
	for key, holders := range r.config.Holders.Buckets() {
		if h, ok := holders.Load(p.ID); ok && key[0] == 'n' && h.ReadyBoundaryMode == changed.ReadyBoundaryMode {
			live++
		}
	}
	if live != fresh-overlap {
		t.Fatalf("%d of %d rows parked under the new capability became live holders", live, fresh-overlap)
	}
}

// A drop recorded by one apply yields to a later apply that republished the
// epoch: two heartbeats move a model from epoch A to B and back to A, and
// the first apply's drop, running after the second apply bound a chunk of
// A's rows, must leave the rest for the bind rather than delete them. A
// session that lost its ID leaves the rows parked.
func TestCacheRoutingPersistenceStaleDropYieldsToRepublishedEpoch(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	r, _, capability := newPersistenceFixture(t)
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	startPersistence(t, r, st)
	p := persistenceTestProvider(t, r, "machine-a", capability)
	persister := r.persister
	now := time.Now()
	const parked = 2*cachetracker.BindChunkRows + 5
	for i := 0; i < parked; i++ {
		persister.Park(crs.HolderRecord{
			Key: fmt.Sprintf("k%05d", i), CacheEpoch: capability.CacheEpoch, Tier: "ssd", ModelID: "model",
			ModelAggregateHash: capability.ModelAggregateHash, PromptContractID: capability.PromptContractID,
			BlockHashVersion: capability.BlockHashVersion, ReadyBoundaryMode: capability.ReadyBoundaryMode,
			AnchorTokenCount: 4096, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(time.Minute),
		})
	}
	other := capability
	other.CacheEpoch = "33333333-3333-3333-3333-333333333333"
	// The first heartbeat (A → B) records the drop of A's bucket; before it
	// runs, the second (B → A) applies and binds its first chunk.
	first, err := r.snapshots.Apply(p.ID, true, 2, []protocol.PrefixCacheV2Capability{other}, nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	drops := first.Drops
	if len(drops) != 1 || drops[0].Epoch != capability.CacheEpoch || drops[0].Model != "model" {
		t.Fatalf("the epoch change must record the drop of the old epoch's bucket: %+v", drops)
	}
	second, err := r.snapshots.Apply(p.ID, true, 2, []protocol.PrefixCacheV2Capability{capability}, nil, nil, nil)
	if remaining := second.Remaining; err != nil || !remaining {
		t.Fatalf("the second apply must bind one chunk and report the rest: remaining=%v err=%v", remaining, err)
	}
	for _, d := range drops {
		first.SettleDrop(d)
	}
	if s := r.CacheRoutingPersistenceStatus(); s.DroppedPending != 0 || s.PendingHolders != parked-cachetracker.BindChunkRows {
		t.Fatalf("a drop for a republished epoch must leave the rows parked: %+v", s)
	}
	second.BindRemaining()
	if s := r.CacheRoutingPersistenceStatus(); s.BoundHolders != parked || s.PendingHolders != 0 || s.DroppedPending != 0 {
		t.Fatalf("every row must bind: %+v", s)
	}
	// A session that lost its ID stops settling, whatever its last apply
	// left behind: the rows its disconnect parks stay parked for the next
	// session with that epoch or the TTL prune.
	r.Disconnect(p.ID)
	r.maintenance.InvalidateProviderEvidence(p.ID, cachetracker.RemovalDisconnect, true)
	p.Mu().Lock()
	p.PrefixCacheV2Models["model"] = other // the dead session's last apply moved off A
	p.Mu().Unlock()
	if before := r.CacheRoutingPersistenceStatus(); before.PendingHolders != parked {
		t.Fatalf("the disconnect must park every bound row: %+v", before)
	}
	first.SettleDrop(production.CacheParkedDrop{Epoch: capability.CacheEpoch, Model: "model"})
	if after := r.CacheRoutingPersistenceStatus(); after.PendingHolders != parked || after.DroppedPending != 0 {
		t.Fatalf("a replaced session must not settle parked rows: %+v", after)
	}
}

// An expired holder of an older session (not yet swept) is not surviving
// evidence: invalidating the newer session's holder deletes the durable
// row instead of refreshing it from the expired one.
func TestCacheRoutingPersistenceExpiredSessionDoesNotPreserveRow(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	var clock time.Time
	r, _, capability := newPersistenceFixture(t, production.CacheDependencies{Now: func() time.Time { return clock }})
	r.Disconnect("provider-a")
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	base := time.Now().Add(-10 * time.Second)
	clock = base
	startPersistence(t, r, st)
	checkpoint := exactTestAnchor(16, "c")
	floor := exactTestAnchor(17, "d")
	plan := persistenceBoundPlan(r, exactTestPlan(checkpoint, floor))
	older := persistenceTestProvider(t, r, "session-older", capability)
	newer := persistenceTestProvider(t, r, "session-newer", capability)
	receipt := func(p *production.Provider, id string) {
		_, ready := persistenceAttempt(t, r, p, capability, id, plan, 1)
		ready.ReadyAnchors = []protocol.PrefixCacheAnchor{checkpoint}
		ready.ExpectedPrefillTokensSaved = checkpoint.TokenCount
		if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
			t.Fatalf("receipt for %s rejected", p.ID)
		}
	}
	receipt(older, "donor-older") // expires at base + 1 min (the test TTL)
	clock = base.Add(50 * time.Second)
	receipt(newer, "donor-newer") // expires at base + 110 s
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Past the older holder's expiry, but before any sweep removed it.
	clock = base.Add(65 * time.Second)
	r.maintenance.InvalidateProviderEvidence(newer.ID, cachetracker.RemovalProofMismatch, true)
	if err := r.FlushCacheRoutingState(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rows, _ := st.LoadCacheHolders(context.Background(), base.Add(65*time.Second), 0, 0); len(rows) != 0 {
		t.Fatalf("an expired session must not preserve the durable row: %+v", rows)
	}
}
