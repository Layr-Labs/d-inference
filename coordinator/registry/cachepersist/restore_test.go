package cachepersist

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

func TestRestoreClampsToCurrentTTLAndKeepsLongestLived(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	now := time.Now()
	ctx := context.Background()
	// Written under a 60-minute TTL 20 minutes ago; today's TTL is 29 minutes.
	old := rec("old", "e", now.Add(-20*time.Minute), 60*time.Minute)
	stale := rec("stale", "e", now.Add(-40*time.Minute), 60*time.Minute) // past UpdatedAt+29m
	fresh := rec("fresh", "e", now, 29*time.Minute)
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{old, stale, fresh}); err != nil {
		t.Fatal(err)
	}
	if err := mem.UpsertCacheDemand(ctx, []crs.DemandRecord{{Key: "d", SeenAt: now}}); err != nil {
		t.Fatal(err)
	}
	p := New(mem, nil, Options{MaxPending: 1000})
	demand, err := p.Restore(ctx, now, 29*time.Minute, 1000, 0)
	if err != nil || len(demand) != 1 {
		t.Fatalf("restore: %v %+v", err, demand)
	}
	// The store applies the clamp itself: the stale row never loads, the old
	// row arrives clamped.
	if s := p.Status(); s.RestoredHolders != 2 || s.DroppedPending != 0 {
		t.Fatalf("stale row must not load, old row clamped: %+v", s)
	}
	rows, _ := p.Take("e", "model", 0)
	for _, r := range rows {
		if r.Key == "old" && !r.ExpiresAt.Equal(r.UpdatedAt.Add(29*time.Minute)) {
			t.Fatalf("old row not clamped to the current TTL: %+v", r)
		}
	}
	// A capped restore keeps the rows that live longest under today's TTL:
	// old's stored expiry is later, but clamped it has 9 minutes left against
	// fresh's 29.
	p2 := New(mem, nil, Options{MaxPending: 1000})
	if _, err := p2.Restore(ctx, now, 29*time.Minute, 1, 0); err != nil {
		t.Fatal(err)
	}
	if rows, _ := p2.Take("e", "model", 0); len(rows) != 1 || rows[0].Key != "fresh" {
		t.Fatalf("capped restore must keep the row with the most life under the current TTL: %+v", rows)
	}
}

// After a TTL reduction, rows written under the old TTL sort first by their
// stored expiry although the clamp drops them. The cap must apply after the
// clamp, or a cap-sized set of such rows hides every valid row behind it.
func TestRestoreCapAppliesCurrentTTLBeforeLimit(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	rows := []crs.HolderRecord{
		rec("stale-1", "e", now.Add(-35*time.Minute), 60*time.Minute), // stored expiry now+25m; expired under 29m
		rec("stale-2", "e", now.Add(-33*time.Minute), 60*time.Minute), // stored expiry now+27m; expired under 29m
		rec("valid", "e", now.Add(-5*time.Minute), 29*time.Minute),    // stored expiry now+24m; 24m left
	}
	if err := mem.UpsertCacheHolders(ctx, rows); err != nil {
		t.Fatal(err)
	}
	p := New(mem, nil, Options{MaxPending: 10})
	if _, err := p.Restore(ctx, now, 29*time.Minute, 1, 0); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.RestoredHolders != 1 || s.DroppedPending != 0 {
		t.Fatalf("the cap must be filled with rows valid under the current TTL: %+v", s)
	}
	if got, _ := p.Take("e", "model", 0); len(got) != 1 || got[0].Key != "valid" || !got[0].ExpiresAt.Equal(now.Add(24*time.Minute)) {
		t.Fatalf("capped restore hid the valid row behind clamped-away rows: %+v", got)
	}
}

func TestRestoreResetsRowsFromAnotherKeyGeneration(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	if err := mem.ResetCacheRoutingState(ctx, "gen-1"); err != nil {
		t.Fatal(err)
	}
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{rec("a", "e", now, time.Minute)}); err != nil {
		t.Fatal(err)
	}
	if err := mem.UpsertCacheDemand(ctx, []crs.DemandRecord{{Key: "d", SeenAt: now}}); err != nil {
		t.Fatal(err)
	}
	// The same generation restores.
	same := New(mem, nil, Options{MaxPending: 10, Fingerprint: "gen-1"})
	demand, err := same.Restore(ctx, now, time.Minute, 10, 10)
	if err != nil || len(demand) != 1 || same.Status().RestoredHolders != 1 || same.Status().KeyRotated {
		t.Fatalf("same generation must restore: %v %+v %+v", err, demand, same.Status())
	}
	// A rotated master key resets both tables and records the new generation
	// instead of parking rows whose keys can never match a request again.
	rotated := New(mem, nil, Options{MaxPending: 10, Fingerprint: "gen-2"})
	demand, err = rotated.Restore(ctx, now, time.Minute, 10, 10)
	if err != nil || len(demand) != 0 {
		t.Fatalf("rotation must not hand back old demand: %v %+v", err, demand)
	}
	if s := rotated.Status(); s.RestoredHolders != 0 || s.PendingHolders != 0 || !s.KeyRotated {
		t.Fatalf("rotation must reset instead of restore: %+v", s)
	}
	if fp, err := mem.CacheRoutingKeyFingerprint(ctx); err != nil || fp != "gen-2" {
		t.Fatalf("new generation not recorded: %q %v", fp, err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, 0, 0); len(rows) != 0 {
		t.Fatalf("old-generation holder rows survived the reset: %d", len(rows))
	}
	if rows, _ := mem.LoadCacheDemand(ctx, now.Add(-time.Minute), now.Add(time.Minute), 0); len(rows) != 0 {
		t.Fatalf("old-generation demand rows survived the reset: %d", len(rows))
	}
	// The next boot under the new generation restores what it wrote.
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{rec("b", "e", now, time.Minute)}); err != nil {
		t.Fatal(err)
	}
	next := New(mem, nil, Options{MaxPending: 10, Fingerprint: "gen-2"})
	if _, err := next.Restore(ctx, now, time.Minute, 10, 10); err != nil || next.Status().RestoredHolders != 1 || next.Status().KeyRotated {
		t.Fatalf("new generation must restore its own rows: %v %+v", err, next.Status())
	}
	// A first boot with no recorded generation stamps it without reporting a rotation.
	fresh := New(store.NewMemory(store.Config{}), nil, Options{MaxPending: 10, Fingerprint: "gen-1"})
	if _, err := fresh.Restore(ctx, now, time.Minute, 10, 10); err != nil || fresh.Status().KeyRotated {
		t.Fatalf("first boot must not report a rotation: %v %+v", err, fresh.Status())
	}
}

func TestDemandGranularityFollowsShortTTLAndRestoreIsCapped(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	// A 30 s TTL bounds the granularity to 7.5 s; the default minute would
	// leave the durable timestamp older than the TTL while the key is still
	// hot in memory, so it would not survive a restart.
	p := New(mem, nil, Options{MaxPending: 10, DemandTTL: 30 * time.Second})
	if p.demandGranularity != 7500*time.Millisecond {
		t.Fatalf("granularity not bounded by the TTL: %v", p.demandGranularity)
	}
	restoreForTest(t, p, now)
	p.MarkDemand([]string{"k"}, now)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.MarkDemand([]string{"k"}, now.Add(5*time.Second))
	if b := pendingBatch(p); len(b.demand) != 0 {
		t.Fatalf("refresh inside the granularity must be skipped: %+v", b.demand)
	}
	p.MarkDemand([]string{"k"}, now.Add(20*time.Second))
	if b := pendingBatch(p); len(b.demand) != 1 || !b.demand[0].SeenAt.Equal(now.Add(20*time.Second)) {
		t.Fatalf("refresh past the granularity must persist: %+v", b.demand)
	}
	// A long TTL keeps the default minute.
	if q := New(mem, nil, Options{MaxPending: 10, DemandTTL: 29 * time.Minute}); q.demandGranularity != DemandPersistGranularity {
		t.Fatalf("long TTL must keep the default granularity: %v", q.demandGranularity)
	}
	// A capped restore keeps the newest demand keys and stays within the TTL.
	mem = store.NewMemory(store.Config{})
	var rows []crs.DemandRecord
	for i := 0; i < 5; i++ {
		rows = append(rows, crs.DemandRecord{Key: string(rune('a' + i)), SeenAt: now.Add(time.Duration(i) * time.Second)})
	}
	rows = append(rows, crs.DemandRecord{Key: "expired", SeenAt: now.Add(-2 * time.Minute)})
	if err := mem.UpsertCacheDemand(ctx, rows); err != nil {
		t.Fatal(err)
	}
	demand, err := New(mem, nil, Options{MaxPending: 10}).Restore(ctx, now.Add(10*time.Second), time.Minute, 10, 2)
	if err != nil || len(demand) != 2 || demand[0].Key != "e" || demand[1].Key != "d" {
		t.Fatalf("capped demand restore must keep the newest keys: %+v %v", demand, err)
	}
	demand, err = New(mem, nil, Options{MaxPending: 10}).Restore(ctx, now.Add(10*time.Second), time.Minute, 10, 0)
	if err != nil || len(demand) != 5 {
		t.Fatalf("uncapped restore must drop only the expired key: %+v %v", demand, err)
	}
}

// Demand rows stamped after now by a previous instance's fast clock are not
// restored, and only the entries the registry's index accepted are treated as
// already persisted.
func TestRestoreBoundsDemandToNowAndSeedsOnlyAcceptedKeys(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	if err := mem.UpsertCacheDemand(ctx, []crs.DemandRecord{
		{Key: "future", SeenAt: now.Add(time.Hour)},
		{Key: "fresh", SeenAt: now.Add(-time.Second)},
		{Key: "edge", SeenAt: now.Add(-time.Minute)},
	}); err != nil {
		t.Fatal(err)
	}
	p := New(mem, nil, Options{MaxPending: 10, DemandTTL: time.Minute})
	demand, err := p.Restore(ctx, now, time.Minute, 10, 1)
	if err != nil || len(demand) != 1 || demand[0].Key != "fresh" {
		t.Fatalf("the future row must not take the cap: %+v %v", demand, err)
	}
	if s := p.Status(); s.RestoredDemand != 0 {
		t.Fatalf("nothing counts as restored before the index accepts it: %+v", s)
	}
	// The registry accepted "fresh" only; "edge" (rejected by the index) is
	// not seeded, so its next observation is written.
	p.SeedDemandPersisted([]crs.DemandRecord{{Key: "fresh", SeenAt: now.Add(-time.Second)}})
	if s := p.Status(); s.RestoredDemand != 1 {
		t.Fatalf("restored demand counts accepted entries: %+v", s)
	}
	p.MarkDemand([]string{"fresh", "edge", "future"}, now)
	b := pendingBatch(p)
	keys := map[string]bool{}
	for _, d := range b.demand {
		keys[d.Key] = true
	}
	if keys["fresh"] || !keys["edge"] || !keys["future"] {
		t.Fatalf("seeded key suppressed, others written: %+v", b.demand)
	}
}

// A retried restore merges the store's rows into whatever this run already
// parked: a provider that disconnected before the retry parked newer
// evidence the store does not hold yet, and it must survive the restore.
func TestRestoreMergesIntoRowsParkedBeforeIt(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	older := rec("a", "e", now.Add(-30*time.Second), time.Minute)
	older.StageMs = 20
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{older, rec("b", "e", now, time.Minute)}); err != nil {
		t.Fatal(err)
	}
	p := New(mem, nil, Options{MaxPending: 10})
	newer := rec("a", "e", now, time.Minute)
	newer.StageMs = 50
	p.Park(newer)
	if _, err := p.Restore(ctx, now, time.Minute, 10, 10); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.PendingHolders != 2 || s.RestoredHolders != 2 || s.DroppedPending != 0 {
		t.Fatalf("restore must merge into the parked rows: %+v", s)
	}
	rows, _ := p.Take("e", "model", 0)
	byKey := map[string]crs.HolderRecord{}
	for _, r := range rows {
		byKey[r.Key] = r
	}
	if len(rows) != 2 || byKey["a"].StageMs != 50 || !byKey["a"].UpdatedAt.Equal(now) || byKey["b"].Key != "b" {
		t.Fatalf("parked newer evidence must win over the store's older copy: %+v", rows)
	}
}

// Rows parked while the restore was unavailable can expire before a retry
// succeeds; they must not take the cap from rows the store still holds.
func TestRestoreDropsExpiredParkedRowsBeforeTheCap(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{rec("durable", "e", now, time.Minute)}); err != nil {
		t.Fatal(err)
	}
	p := New(mem, nil, Options{MaxPending: 2})
	// Not ready: the prune loop cannot reach the store, but parked rows
	// still expire in process.
	p.Park(rec("expired", "e", now.Add(-2*time.Minute), time.Minute))       // expires now-60s
	p.Park(rec("expired-too", "e", now.Add(-100*time.Second), time.Minute)) // expires now-40s
	p.Prune(ctx, now.Add(-90*time.Second), time.Minute)                     // both still live then
	if s := p.Status(); s.PendingHolders != 2 || s.Ready {
		t.Fatalf("parked rows must survive an early prune while not ready: %+v", s)
	}
	// A prune tick drops expired parked rows even while the store is
	// unreachable (the persister is not ready).
	p.Prune(ctx, now.Add(-50*time.Second), time.Minute) // "expired" has lapsed, "expired-too" not yet
	if s := p.Status(); s.PendingHolders != 1 || s.DroppedPending != 1 || s.Ready {
		t.Fatalf("prune must drop expired parked rows before the restore succeeds: %+v", s)
	}
	if _, err := p.Restore(ctx, now, time.Minute, 2, 0); err != nil {
		t.Fatal(err)
	}
	rows, _ := p.Take("e", "model", 0)
	if len(rows) != 1 || rows[0].Key != "durable" {
		t.Fatalf("the expired parked row must not take the cap from the durable row: %+v", rows)
	}
	if s := p.Status(); s.RestoredHolders != 1 || s.DroppedPending != 2 {
		t.Fatalf("expired parked row dropped, durable row restored: %+v", s)
	}
}

// A row another instance stamped ahead of this clock is removed at restore,
// so this run's receipts for the same key reach the store instead of being
// outranked by the future timestamp.
func TestRestoreRemovesFutureDatedRows(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	future := rec("a", "e", now.Add(2*time.Hour), time.Minute)
	future.StageMs = 999
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{future}); err != nil {
		t.Fatal(err)
	}
	p := New(mem, nil, Options{MaxPending: 10})
	if _, err := p.Restore(ctx, now, time.Minute, 10, 10); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.RestoredHolders != 0 {
		t.Fatalf("a future-dated row must not restore: %+v", s)
	}
	current := rec("a", "e", now, time.Minute)
	current.StageMs = 50
	p.MarkHolderUpsert(current)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	rows, _ := mem.LoadCacheHolders(ctx, now, 0, 0)
	if len(rows) != 1 || rows[0].StageMs != 50 || !rows[0].UpdatedAt.Equal(now) {
		t.Fatalf("this run's receipt must replace the future-dated row: %+v", rows)
	}
}

// A backlog overflow while the rows are loading releases decisions that
// condemn rows no per-row check can see: the restore resets instead of
// parking them.
func TestRestoreResetsWhenTheBacklogOverflowsDuringTheLoad(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	condemned := rec("condemned", "e", now, time.Minute)
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{condemned}); err != nil {
		t.Fatal(err)
	}
	st := &loadHookStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	st.onLoadHolders = func() {
		// The row's decision is released by the overflow the fillers cause.
		p.MarkHolderDelete(condemned.HolderKey(), now.Add(time.Second))
		for i := 0; i < p.dirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	restoreForTest(t, p, now)
	if s := p.Status(); s.RestoredHolders != 0 || s.PendingHolders != 0 || s.OverflowResets != 1 || !s.Ready || st.resets != 1 {
		t.Fatalf("an overflow during the load must turn the restore into a reset: %+v resets=%d", s, st.resets)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 {
		t.Fatalf("the reset must remove the condemned row: %+v", rows)
	}
}

// An overflow during a load that returns nothing still turns the restore
// into a reset: only the check after the merge loop sees it, and the copy
// must not count as established with released decisions outstanding.
func TestRestoreResetsWhenTheBacklogOverflowsDuringAnEmptyLoad(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	now := time.Now()
	st := &loadHookStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	st.onLoadHolders = func() {
		for i := 0; i <= p.dirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	restoreForTest(t, p, now)
	p.mu.Lock()
	pending := p.resetPending
	p.mu.Unlock()
	if s := p.Status(); !s.Ready || s.OverflowResets != 1 || st.resets != 1 || pending {
		t.Fatalf("an overflow during an empty load must reset before the copy counts as established: %+v resets=%d pending=%v", s, st.resets, pending)
	}
}

// A reset interrupted between its batched deletes leaves the in-progress
// marker as the recorded generation, so the next boot completes it instead
// of restoring the rows it had condemned, without counting a key rotation.
func TestRestoreCompletesAnInterruptedReset(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	// The crash left the marker recorded and a residual row behind.
	if err := mem.ResetCacheRoutingState(ctx, crs.ResetInProgress); err != nil {
		t.Fatal(err)
	}
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{rec("residual", "e", now, time.Minute)}); err != nil {
		t.Fatal(err)
	}
	p := New(mem, nil, Options{MaxPending: 10, Fingerprint: "fp"})
	restoreForTest(t, p, now)
	if s := p.Status(); s.RestoredHolders != 0 || s.KeyRotated || !s.Ready {
		t.Fatalf("an interrupted reset must be completed, not counted as a rotation: %+v", s)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 {
		t.Fatalf("the residual row must be gone: %+v", rows)
	}
	if fp, _ := mem.CacheRoutingKeyFingerprint(ctx); fp != "fp" {
		t.Fatalf("the generation must be recorded once the reset completed: %q", fp)
	}
}

// loadHookStore runs a hook inside the holder load (the window between a
// restore's first overflow check and its merge) and counts resets.
type loadHookStore struct {
	crs.Store
	onLoadHolders func()
	resets        int
}

func (s *loadHookStore) LoadCacheHolders(ctx context.Context, now time.Time, ttl time.Duration, limit int) ([]crs.HolderRecord, error) {
	if hook := s.onLoadHolders; hook != nil {
		s.onLoadHolders = nil
		hook()
	}
	return s.Store.LoadCacheHolders(ctx, now, ttl, limit)
}

func (s *loadHookStore) ResetCacheRoutingState(ctx context.Context, fingerprint string) error {
	s.resets++
	return s.Store.ResetCacheRoutingState(ctx, fingerprint)
}
