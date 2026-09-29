package cachepersist

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	crs "github.com/eigeninference/d-inference/coordinator/store/cacheroutingstate"
)

// flakyStore fails every write while broken is set.
type flakyStore struct {
	crs.Store
	broken bool
}

func (f *flakyStore) UpsertCacheHolders(ctx context.Context, r []crs.HolderRecord) error {
	if f.broken {
		return errors.New("store down")
	}
	return f.Store.UpsertCacheHolders(ctx, r)
}

func (f *flakyStore) DeleteCacheHolders(ctx context.Context, k []crs.HolderKey) error {
	if f.broken {
		return errors.New("store down")
	}
	return f.Store.DeleteCacheHolders(ctx, k)
}

func (f *flakyStore) UpsertCacheDemand(ctx context.Context, r []crs.DemandRecord) error {
	if f.broken {
		return errors.New("store down")
	}
	return f.Store.UpsertCacheDemand(ctx, r)
}

// restoreForTest records the key generation so writes are unblocked, as the
// boot restore does in production.
func restoreForTest(t *testing.T, p *Persister, now time.Time) {
	t.Helper()
	if _, err := p.Restore(context.Background(), now, time.Minute, 1000, 0); err != nil {
		t.Fatalf("restore: %v", err)
	}
}

func rec(key, epoch string, now time.Time, ttl time.Duration) crs.HolderRecord {
	return crs.HolderRecord{Key: key, CacheEpoch: epoch, Tier: "ssd", ModelID: "model",
		AnchorTokenCount: 1024, StageMs: 50, UpdatedAt: now, ExpiresAt: now.Add(ttl)}
}

func TestFlushRetriesUnwrittenRemainderAndDedupesDemand(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	flaky := &flakyStore{Store: mem, broken: true}
	p := New(flaky, nil, Options{MaxPending: 1000})
	now := time.Now()
	restoreForTest(t, p, now)
	p.MarkHolderUpsert(rec("key-1", "e", now, time.Minute))
	p.MarkDemand([]string{"d-1", "d-2"}, now)
	if err := p.Flush(context.Background()); err == nil {
		t.Fatal("flush must report the store failure")
	}
	if s := p.Status(); s.FlushErrors != 1 || s.RowsWritten != 0 || p.dirtyEmpty() {
		t.Fatalf("failure must keep the batch dirty: %+v", s)
	}
	flaky.broken = false
	if err := p.Flush(context.Background()); err != nil {
		t.Fatalf("retry flush: %v", err)
	}
	if rows, _ := mem.LoadCacheHolders(context.Background(), now, 0, 0); len(rows) != 1 {
		t.Fatalf("requeued holder not written: %d", len(rows))
	}
	if d, _ := mem.LoadCacheDemand(context.Background(), now.Add(-time.Minute), now.Add(time.Minute), 0); len(d) != 2 {
		t.Fatalf("requeued demand not written: %d", len(d))
	}
	// Within the granularity window the same key is not written again.
	p.MarkDemand([]string{"d-1"}, now.Add(10*time.Second))
	if b := p.drain(); len(b.demand) != 0 {
		t.Fatalf("demand key re-marked inside the granularity window: %+v", b.demand)
	}
	p.MarkDemand([]string{"d-1"}, now.Add(2*time.Minute))
	if b := p.drain(); len(b.demand) != 1 {
		t.Fatalf("demand key not re-marked after the window: %+v", b.demand)
	}
}

func TestFlushWritesInBoundedChunksAndKeepsPartialProgress(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 100_000})
	now := time.Now()
	restoreForTest(t, p, now)
	for i := 0; i < HolderFlushRows+300; i++ {
		p.MarkHolderUpsert(rec("k"+time.Duration(i).String(), "e", now, time.Minute))
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.RowsWritten != HolderFlushRows || p.dirtyEmpty() {
		t.Fatalf("one flush must write at most %d holders and carry the rest: %+v", HolderFlushRows, s)
	}
	if err := p.FlushAll(context.Background()); err != nil || !p.dirtyEmpty() {
		t.Fatalf("FlushAll must drain the remainder: %v", err)
	}
	if rows, _ := mem.LoadCacheHolders(context.Background(), now, 0, 0); len(rows) != HolderFlushRows+300 {
		t.Fatalf("rows written: %d", len(rows))
	}
}

func TestPendingParkTakeAndPrune(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 2})
	now := time.Now()
	restoreForTest(t, p, now)
	p.Park(rec("a", "e1", now, time.Minute))
	p.Park(rec("b", "e1", now, -time.Second)) // already expired
	p.Park(rec("c", "e1", now, time.Minute))  // over the cap of 2
	if s := p.Status(); s.PendingHolders != 2 || s.DroppedPending != 1 || !p.HasPending() {
		t.Fatalf("park accounting: %+v", s)
	}
	if rows, _ := p.Take("e1", "other-model", 0); rows != nil {
		t.Fatalf("another model must not take the rows: %+v", rows)
	}
	p.prunePending(now)
	if s := p.Status(); s.PendingHolders != 1 || s.DroppedPending != 2 {
		t.Fatalf("prune must drop the expired row: %+v", s)
	}
	rows, _ := p.Take("e1", "model", 0)
	if len(rows) != 1 || rows[0].Key != "a" || p.HasPending() {
		t.Fatalf("take: %+v", rows)
	}
	p.AddBound(1, 0)
	// A capability that is gone: the registry takes the rows, settles each
	// durable row (here: delete) and reports them dropped.
	p.Park(rec("d", "e2", now, time.Minute))
	taken, _ := p.Take("e2", "model", 0)
	for _, r := range taken {
		p.MarkHolderDelete(r.HolderKey(), time.Now())
		p.AddBound(0, 1)
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.BoundHolders != 1 || s.PendingHolders != 0 || s.DroppedPending != 3 || s.RowsDeleted != 1 {
		t.Fatalf("dropped rows must be deleted and counted: %+v", s)
	}
}

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
	if b := p.drain(); len(b.demand) != 0 {
		t.Fatalf("refresh inside the granularity must be skipped: %+v", b.demand)
	}
	p.MarkDemand([]string{"k"}, now.Add(20*time.Second))
	if b := p.drain(); len(b.demand) != 1 || !b.demand[0].SeenAt.Equal(now.Add(20*time.Second)) {
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
	b := p.drain()
	keys := map[string]bool{}
	for _, d := range b.demand {
		keys[d.Key] = true
	}
	if keys["fresh"] || !keys["edge"] || !keys["future"] {
		t.Fatalf("seeded key suppressed, others written: %+v", b.demand)
	}
}

// Nothing is written before Restore has established the key generation:
// the next boot would treat such rows as foreign and reset them.
func TestFlushWaitsForRestore(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 10, Fingerprint: "gen-1"})
	p.MarkHolderUpsert(rec("a", "e", now, time.Minute))
	p.MarkDemand([]string{"d"}, now)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if err := p.FlushAll(ctx); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.Ready || s.Flushes != 0 || s.RowsWritten != 0 || p.dirtyEmpty() {
		t.Fatalf("flush must be a no-op that keeps the marks while not ready: %+v", s)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, 0, 0); len(rows) != 0 {
		t.Fatalf("rows written before the generation was recorded: %+v", rows)
	}
	if _, err := p.Restore(ctx, now, time.Minute, 10, 10); err != nil {
		t.Fatal(err)
	}
	if !p.Ready() {
		t.Fatal("restore must mark the persister ready")
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.RowsWritten != 2 || !p.dirtyEmpty() {
		t.Fatalf("marks made before the restore must be written after it: %+v", s)
	}
	if fp, _ := mem.CacheRoutingKeyFingerprint(ctx); fp != "gen-1" {
		t.Fatalf("generation not recorded: %q", fp)
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

// Receipt times are sampled before the tracker lock: a delayed older receipt
// for a row shared by overlapping sessions must not overwrite the newer
// evidence already queued for the same (key, epoch).
func TestMarkHolderUpsertKeepsTheNewerQueuedRecord(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 10})
	now := time.Now()
	newer := rec("a", "e", now, time.Minute)
	newer.StageMs = 900
	older := rec("a", "e", now.Add(-time.Second), 2*time.Minute) // longer stored lifetime, older evidence
	older.StageMs = 50
	p.MarkHolderUpsert(newer)
	p.MarkHolderUpsert(older)
	b := p.drain()
	if len(b.upserts) != 1 || b.upserts[0].StageMs != 900 || !b.upserts[0].UpdatedAt.Equal(now) ||
		!b.upserts[0].ExpiresAt.Equal(now.Add(-time.Second).Add(2*time.Minute)) {
		t.Fatalf("queued upsert must keep the newer record and the later expiry: %+v", b.upserts)
	}
}

// A batch that failed to write is requeued by merging with whatever was
// marked meanwhile: a delayed older receipt must not displace the newer
// drained record, nor the other way round.
func TestRequeueMergesWithEvidenceQueuedMeanwhile(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 10})
	now := time.Now()
	newer := rec("a", "e", now, time.Minute)
	newer.StageMs = 900
	older := rec("a", "e", now.Add(-time.Second), time.Minute)
	older.StageMs = 50
	// The older receipt was marked while the newer one's batch was in flight.
	p.MarkHolderUpsert(older)
	p.requeue(batch{upserts: []crs.HolderRecord{newer}})
	if b := p.drain(); len(b.upserts) != 1 || b.upserts[0].StageMs != 900 {
		t.Fatalf("requeue must keep the newer drained record: %+v", b.upserts)
	}
	// And the newer mark wins over an older drained record.
	p.MarkHolderUpsert(newer)
	p.requeue(batch{upserts: []crs.HolderRecord{older}})
	if b := p.drain(); len(b.upserts) != 1 || b.upserts[0].StageMs != 900 {
		t.Fatalf("requeue must keep the newer queued record: %+v", b.upserts)
	}
}

// Overlapping sessions park the same durable row more than once; one parked
// copy per (key, epoch) keeps the newer evidence and takes one cap slot.
func TestParkDedupesByHolderIdentity(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 2})
	now := time.Now()
	older := rec("a", "e", now.Add(-time.Second), time.Minute)
	older.StageMs = 50
	newer := rec("a", "e", now, time.Minute)
	newer.StageMs = 900
	p.Park(older)
	p.Park(newer)
	p.Park(older) // a late duplicate of the older session
	p.Park(rec("b", "e", now, time.Minute))
	if s := p.Status(); s.PendingHolders != 2 || s.DroppedPending != 0 {
		t.Fatalf("duplicates must not consume the cap: %+v", s)
	}
	rows, _ := p.Take("e", "model", 0)
	byKey := map[string]crs.HolderRecord{}
	for _, r := range rows {
		byKey[r.Key] = r
	}
	if len(rows) != 2 || byKey["a"].StageMs != 900 || byKey["b"].Key != "b" {
		t.Fatalf("one parked copy per identity with the newer evidence: %+v", rows)
	}
}

// A tombstone outranks older parked evidence for one TTL after it was
// written: a row an older session parked before the decision must not bind
// once the flush has drained the tombstone.
func TestTombstoneOutlivesItsFlushForOneTTL(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 10})
	restoreForTest(t, p, now)
	k := crs.HolderKey{Key: "a", CacheEpoch: "e"}
	before := now.Add(-time.Second)
	p.MarkHolderDelete(k, time.Now()) // decided now
	if !p.Tombstoned(k, before) {
		t.Fatal("a pending delete outranks any row")
	}
	// In flight: the delete has left the dirty set but is not written yet.
	b := p.drain()
	if len(b.deletes) != 1 || !p.Tombstoned(k, before) {
		t.Fatalf("a delete in flight must still outrank older evidence: %+v", b.deletes)
	}
	p.requeue(b)
	if !p.Tombstoned(k, before) {
		t.Fatal("a requeued delete must still outrank older evidence")
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if !p.Tombstoned(k, before) {
		t.Fatal("a written delete must still outrank evidence from before it")
	}
	if p.Tombstoned(k, time.Now().Add(time.Second)) {
		t.Fatal("evidence produced after the decision is not tombstoned")
	}
	if p.Tombstoned(crs.HolderKey{Key: "a", CacheEpoch: "other"}, before) {
		t.Fatal("another epoch's row is not tombstoned")
	}
	p.Prune(ctx, now.Add(2*time.Minute), time.Minute)
	if p.Tombstoned(k, before) {
		t.Fatal("a tombstone lapses after one TTL")
	}
}

// A receipt sampled before an invalidation of the same durable row but
// applied after it must not cancel the tombstone or reach the store; a
// receipt newer than the decision re-proves the row and cancels it.
func TestDelayedOlderReceiptCannotCancelANewerTombstone(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 10})
	restoreForTest(t, p, now)
	stale := rec("a", "e", now.Add(-time.Second), time.Minute)
	p.MarkHolderDelete(stale.HolderKey(), time.Now()) // decided now, after the stale receipt's time
	p.MarkHolderUpsert(stale)
	if b := p.drain(); len(b.deletes) != 1 || len(b.upserts) != 0 {
		t.Fatalf("stale receipt must neither cancel the tombstone nor queue: %+v %+v", b.deletes, b.upserts)
	}
	// The tombstone is in flight (drained, not yet written): still stale.
	p.MarkHolderUpsert(stale)
	if !p.dirtyEmpty() {
		t.Fatal("stale receipt queued while the tombstone is in flight")
	}
	fresh := rec("a", "e", time.Now().Add(time.Second), time.Minute)
	p.MarkHolderUpsert(fresh)
	if b := p.drain(); len(b.upserts) != 1 || !b.upserts[0].UpdatedAt.Equal(fresh.UpdatedAt) {
		t.Fatalf("a receipt newer than the decision re-proves the row: %+v", b.upserts)
	}
	// And a pending tombstone is cancelled only by a newer receipt.
	p.MarkHolderDelete(stale.HolderKey(), time.Now())
	p.MarkHolderUpsert(rec("a", "e", time.Now().Add(2*time.Second), time.Minute))
	if b := p.drain(); len(b.deletes) != 0 || len(b.upserts) != 1 {
		t.Fatalf("newer receipt must cancel the pending tombstone: %+v %+v", b.deletes, b.upserts)
	}
}

// Tombstone retention is bounded by the holder budget as well as the TTL:
// under churn the oldest tombstones are forgotten first.
func TestRecentDeletesBoundedByHolderBudget(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 3})
	p.retentionLimit = 3 // production never goes below one flush batch
	restoreForTest(t, p, now)
	for i := 0; i < 5; i++ {
		p.MarkHolderDelete(crs.HolderKey{Key: string(rune('a' + i)), CacheEpoch: "e"}, time.Now())
		if err := p.Flush(ctx); err != nil {
			t.Fatal(err)
		}
	}
	p.mu.Lock()
	n, order := len(p.recentDeletes), p.recentOrder.Len()
	p.mu.Unlock()
	if n != 3 || order != 3 {
		t.Fatalf("retention must stay within the holder budget: map=%d order=%d", n, order)
	}
	checkRetentionOrder(t, p)
	before := now.Add(-time.Minute)
	if p.Tombstoned(crs.HolderKey{Key: "a", CacheEpoch: "e"}, before) || !p.Tombstoned(crs.HolderKey{Key: "e", CacheEpoch: "e"}, before) {
		t.Fatal("the oldest tombstones must go first")
	}
	// A key decided again moves to the retention tail: with c, d, e kept,
	// deciding c again and then adding f and g must evict d and e, not c.
	time.Sleep(2 * time.Millisecond)
	p.MarkHolderDelete(crs.HolderKey{Key: "c", CacheEpoch: "e"}, time.Now())
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"f", "g"} {
		p.MarkHolderDelete(crs.HolderKey{Key: key, CacheEpoch: "e"}, time.Now())
		if err := p.Flush(ctx); err != nil {
			t.Fatal(err)
		}
	}
	p.mu.Lock()
	n, order = len(p.recentDeletes), p.recentOrder.Len()
	p.mu.Unlock()
	if n != 3 || order != 3 {
		t.Fatalf("retention must stay within the holder budget after refreshes: map=%d order=%d", n, order)
	}
	checkRetentionOrder(t, p)
	if !p.Tombstoned(crs.HolderKey{Key: "c", CacheEpoch: "e"}, before) || p.Tombstoned(crs.HolderKey{Key: "d", CacheEpoch: "e"}, before) {
		t.Fatal("a refreshed decision must outlive older ones")
	}
}

// A delete whose write failed is requeued with its original decision time:
// a receipt newer than that decision still cancels it, and one older than it
// is still rejected, exactly as before the failure.
func TestFailedDeleteWriteKeepsTheDecisionTime(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	flaky := &flakyStore{Store: mem}
	ctx := context.Background()
	now := time.Now()
	p := New(flaky, nil, Options{MaxPending: 10})
	restoreForTest(t, p, now)
	k := crs.HolderKey{Key: "a", CacheEpoch: "e"}
	decided := now
	p.MarkHolderDelete(k, decided)
	flaky.broken = true
	if err := p.Flush(ctx); err == nil {
		t.Fatal("flush must report the failed delete")
	}
	p.mu.Lock()
	at, pending := p.holderDeletes[k]
	p.mu.Unlock()
	if !pending || !at.Equal(decided) {
		t.Fatalf("requeued delete must keep its decision time: pending=%v at=%v want %v", pending, at, decided)
	}
	if !p.Tombstoned(k, decided.Add(-time.Millisecond)) || p.Tombstoned(k, decided.Add(time.Millisecond)) {
		t.Fatal("the tombstone window must not move with the retry")
	}
	// Evidence newer than the decision re-proves the row and cancels the
	// requeued tombstone; the retried flush then writes the row.
	fresh := rec("a", "e", decided.Add(time.Millisecond), time.Minute)
	p.MarkHolderUpsert(fresh)
	flaky.broken = false
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	// Read a second later: the row's update time is just after the decision.
	if rows, _ := mem.LoadCacheHolders(ctx, now.Add(time.Second), 0, 0); len(rows) != 1 {
		t.Fatalf("re-proved row must be written, not deleted: %+v", rows)
	}
	if s := p.Status(); s.StaleUpserts != 0 {
		t.Fatalf("a receipt newer than the decision is not stale: %+v", s)
	}
}

// A delete decided again while its earlier write was failing keeps the later
// decision when the failed batch is requeued.
func TestRequeueKeepsTheLaterDeleteDecision(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 10})
	restoreForTest(t, p, time.Now())
	k := crs.HolderKey{Key: "a", CacheEpoch: "e"}
	first := time.Now()
	second := first.Add(time.Second)
	// The second invalidation was queued while the first's write failed.
	p.MarkHolderDelete(k, second)
	p.requeue(batch{deletes: []crs.HolderKey{k}, deleteAt: map[crs.HolderKey]time.Time{k: first}})
	p.mu.Lock()
	at := p.holderDeletes[k]
	p.mu.Unlock()
	if !at.Equal(second) {
		t.Fatalf("requeue must keep the later decision: got %v want %v", at, second)
	}
	if !p.Tombstoned(k, first.Add(500*time.Millisecond)) {
		t.Fatal("evidence between the two decisions must still be outranked")
	}
	// And a requeue never moves a decision earlier than the drained one either.
	p.MarkHolderDelete(k, first)
	p.requeue(batch{deletes: []crs.HolderKey{k}, deleteAt: map[crs.HolderKey]time.Time{k: second}})
	p.mu.Lock()
	at = p.holderDeletes[k]
	p.mu.Unlock()
	if !at.Equal(second) {
		t.Fatalf("requeue must keep the later of the two decisions: got %v want %v", at, second)
	}
}

// A bounded take hands back at most limit rows and says whether more remain,
// so a large bucket can be bound in chunks.
func TestTakeInChunks(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 10})
	now := time.Now()
	for i := 0; i < 5; i++ {
		p.Park(rec(string(rune('a'+i)), "e", now, time.Minute))
	}
	total := 0
	for i := 0; i < 3; i++ {
		rows, more := p.Take("e", "model", 2)
		total += len(rows)
		if i < 2 && (len(rows) != 2 || !more) {
			t.Fatalf("chunk %d: rows=%d more=%v", i, len(rows), more)
		}
		if i == 2 && (len(rows) != 1 || more) {
			t.Fatalf("last chunk: rows=%d more=%v", len(rows), more)
		}
	}
	if total != 5 || p.HasPending() {
		t.Fatalf("all rows must be taken exactly once: total=%d pending=%v", total, p.HasPending())
	}
}

// Retention evicts by decision time whatever order the decisions were
// recorded in: a newer tombstone is never forgotten before an older one.
func TestRecentDeletesEvictOldestDecisionFirst(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 2})
	p.retentionLimit = 2
	now := time.Now()
	keys := []string{"c", "a", "b"}
	times := []time.Time{now.Add(3 * time.Second), now.Add(1 * time.Second), now.Add(2 * time.Second)}
	p.mu.Lock()
	for i, k := range keys { // recorded out of time order, as one flush may
		p.rememberDeleteLocked(crs.HolderKey{Key: k, CacheEpoch: "e"}, times[i])
	}
	p.mu.Unlock()
	before := now
	if p.Tombstoned(crs.HolderKey{Key: "a", CacheEpoch: "e"}, before) {
		t.Fatal("the oldest decision (a) must be the one evicted")
	}
	for _, k := range []string{"b", "c"} {
		if !p.Tombstoned(crs.HolderKey{Key: k, CacheEpoch: "e"}, before) {
			t.Fatalf("newer decision %s must be retained", k)
		}
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

// A delete decision discards the parked copy it outranks at once, and a row
// parked after the decision with older evidence is refused while the
// decision is pending or retained, so a copy parked before the decision
// never depends on the bounded tombstone retention to stay unbound.
func TestDeleteDecisionDiscardsOutrankedParkedCopy(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 10})
	restoreForTest(t, p, time.Now())
	now := time.Now()
	older := rec("a", "e", now.Add(-time.Second), time.Minute)
	p.Park(older)
	if s := p.Status(); s.PendingHolders != 1 {
		t.Fatalf("parked: %+v", s)
	}
	// Park, then decide: the parked copy goes with the decision.
	p.MarkHolderDelete(older.HolderKey(), now)
	if s := p.Status(); s.PendingHolders != 0 || s.DroppedPending != 1 {
		t.Fatalf("a decision must discard the parked copy it outranks: %+v", s)
	}
	// Decide, then park older evidence: refused. Newer evidence: kept.
	p.Park(older)
	if s := p.Status(); s.PendingHolders != 0 || s.DroppedPending != 2 {
		t.Fatalf("older evidence must not park behind a decision: %+v", s)
	}
	newer := rec("a", "e", now.Add(time.Second), time.Minute)
	p.Park(newer)
	if s := p.Status(); s.PendingHolders != 1 {
		t.Fatalf("newer evidence parks: %+v", s)
	}
	rows, _ := p.Take("e", "model", 0)
	if len(rows) != 1 || !rows[0].UpdatedAt.Equal(newer.UpdatedAt) {
		t.Fatalf("only the newer copy remains parked: %+v", rows)
	}
	if p.HasPending() {
		t.Fatal("take must clear the identity index too")
	}
	// The accepted residual: once a written decision has been evicted from
	// the count-bounded retention, evidence older than it can park again
	// (it can only exist through a receipt sampled before the decision and
	// never re-proved since); the resulting hint self-heals on the next
	// miss. Documented here so the bound is not mistaken for a guarantee.
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	p.retentionLimit = 1
	p.mu.Lock()
	p.rememberDeleteLocked(crs.HolderKey{Key: "b", CacheEpoch: "e"}, now.Add(2*time.Second))
	p.rememberDeleteLocked(crs.HolderKey{Key: "c", CacheEpoch: "e"}, now.Add(3*time.Second))
	p.mu.Unlock()
	p.Park(older)
	if s := p.Status(); s.PendingHolders != 1 {
		t.Fatalf("residual: a forgotten decision no longer refuses older evidence: %+v", s)
	}
}

// A prune pops only the expired parked rows off the expiry order, in
// bounded chunks; rows taken or merged meanwhile have left or moved their
// entry already.
func TestPrunePendingPopsOnlyExpiredRowsInChunks(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 100_000})
	now := time.Now()
	const expired, live = 2*pruneBatchRows + 7, 100
	for i := 0; i < expired; i++ {
		p.Park(rec(fmt.Sprintf("x%05d", i), "e", now.Add(-2*time.Minute), time.Minute)) // expired
	}
	for i := 0; i < live; i++ {
		p.Park(rec(fmt.Sprintf("l%05d", i), "e", now, time.Minute))
	}
	// Extending a live row's expiry by a merge moves its entry in the expiry
	// order rather than adding a second one.
	extended := rec("l00000", "e", now, 2*time.Minute)
	p.Park(extended)
	checkParkedExpiryIndex(t, p)
	// A parked row taken before the prune takes its entry with it.
	taken, _ := p.Take("e", "model", 1)
	if len(taken) != 1 {
		t.Fatal("take one row")
	}
	checkParkedExpiryIndex(t, p)
	// One lock hold drops at most its chunk and reports the rest.
	p.mu.Lock()
	more := p.prunePendingBatchLocked(now, 5)
	dropped := p.counters.droppedPending
	p.mu.Unlock()
	if !more || dropped != 5 {
		t.Fatalf("a bounded chunk must drop exactly its chunk and report more: more=%v dropped=%d", more, dropped)
	}
	checkParkedExpiryIndex(t, p)
	p.Prune(context.Background(), now, time.Minute) // not ready: parked prune only
	checkParkedExpiryIndex(t, p)
	s := p.Status()
	wantLive := live
	if taken[0].Key[0] == 'l' {
		wantLive--
	}
	if s.PendingHolders != wantLive || s.DroppedPending != uint64(expired)-uint64(map[bool]int{true: 1, false: 0}[taken[0].Key[0] == 'x']) {
		t.Fatalf("prune must drop exactly the expired rows: %+v (taken %s)", s, taken[0].Key)
	}
	rows, _ := p.Take("e", "model", 0)
	for _, r := range rows {
		if r.Key[0] != 'l' {
			t.Fatalf("expired row survived the prune: %+v", r)
		}
		if r.Key == "l00000" && !r.ExpiresAt.Equal(now.Add(2*time.Minute)) {
			t.Fatalf("the merged expiry must stand: %+v", r)
		}
	}
	if p.HasPending() {
		t.Fatal("everything live was taken")
	}
}

// checkKeyedTimeHeap asserts an order holds exactly one entry per key of
// the set it indexes (count keys), each at the position its index records,
// with the time the set currently holds for it: the invariant that lets a
// take, a drop, a merge or a refresh touch one entry instead of leaving
// stale ones for a later scan. Called with p.mu held.
func checkKeyedTimeHeap(t *testing.T, name string, h *keyedTimeHeap, count int, timeOf func(crs.HolderKey) (time.Time, bool)) {
	t.Helper()
	if n := h.Len(); n != count || len(h.pos) != n {
		t.Fatalf("%s out of step with its set: entries=%d indexed=%d keys=%d", name, n, len(h.pos), count)
	}
	for i, e := range h.entries {
		if h.pos[e.key] != i {
			t.Fatalf("%s: entry %d for %v indexed at %d", name, i, e.key, h.pos[e.key])
		}
		if at, ok := timeOf(e.key); !ok || !at.Equal(e.at) {
			t.Fatalf("%s: entry for %v names a missing key or a stale time (present=%v entry=%v set=%v)", name, e.key, ok, e.at, at)
		}
	}
}

// checkParkedExpiryIndex asserts the expiry order matches the parked set.
func checkParkedExpiryIndex(t *testing.T, p *Persister) {
	t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	checkKeyedTimeHeap(t, "expiry order", &p.parkedExpiry, p.pendingCount, func(k crs.HolderKey) (time.Time, bool) {
		row, ok := p.pending[p.parkedBucket[k]][k]
		return row.ExpiresAt, ok
	})
}

// checkRetentionOrder asserts the retention order matches the retained
// decisions.
func checkRetentionOrder(t *testing.T, p *Persister) {
	t.Helper()
	p.mu.Lock()
	defer p.mu.Unlock()
	checkKeyedTimeHeap(t, "retention order", &p.recentOrder, len(p.recentDeletes), func(k crs.HolderKey) (time.Time, bool) {
		at, ok := p.recentDeletes[k]
		return at, ok
	})
}

// A prune forgets only the decisions older than the TTL, oldest first, in
// bounded chunks per lock hold; a refreshed decision moves in the order
// instead of leaving a stale entry behind.
func TestPruneForgetsExpiredDecisionsInChunks(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 100_000})
	now := time.Now()
	const old, fresh = 2*pruneBatchRows + 7, 100
	p.mu.Lock()
	for i := 0; i < old; i++ {
		p.rememberDeleteLocked(crs.HolderKey{Key: fmt.Sprintf("o%05d", i), CacheEpoch: "e"}, now.Add(-2*time.Minute))
	}
	for i := 0; i < fresh; i++ {
		p.rememberDeleteLocked(crs.HolderKey{Key: fmt.Sprintf("f%05d", i), CacheEpoch: "e"}, now)
	}
	// Decided again, later: the entry moves to the fresh end. Decided again,
	// earlier: ignored, the later decision stands.
	p.rememberDeleteLocked(crs.HolderKey{Key: "o00000", CacheEpoch: "e"}, now)
	p.rememberDeleteLocked(crs.HolderKey{Key: "f00000", CacheEpoch: "e"}, now.Add(-3*time.Minute))
	if at := p.recentDeletes[crs.HolderKey{Key: "f00000", CacheEpoch: "e"}]; !at.Equal(now) {
		t.Fatalf("an earlier re-decision must not move a retained decision back: %v", at)
	}
	p.mu.Unlock()
	checkRetentionOrder(t, p)
	// One lock hold forgets at most its chunk and reports the rest.
	p.mu.Lock()
	more := p.forgetDecisionsBatchLocked(now, time.Minute, 5)
	kept := len(p.recentDeletes)
	p.mu.Unlock()
	if !more || kept != old+fresh-5 {
		t.Fatalf("a bounded chunk must forget exactly its chunk and report more: more=%v kept=%d", more, kept)
	}
	checkRetentionOrder(t, p)
	p.Prune(context.Background(), now, time.Minute) // not ready: in-process prunes only
	checkRetentionOrder(t, p)
	p.mu.Lock()
	kept = len(p.recentDeletes)
	_, refreshed := p.recentDeletes[crs.HolderKey{Key: "o00000", CacheEpoch: "e"}]
	p.mu.Unlock()
	if kept != fresh+1 || !refreshed {
		t.Fatalf("a prune must forget exactly the expired decisions: kept=%d refreshed=%v", kept, refreshed)
	}
}

// resetCountingStore counts the durable-copy resets a persister asks for.
type resetCountingStore struct {
	crs.Store
	resets   int           // attempts, failed ones included
	failNext int           // resets to fail before letting one through
	slow     time.Duration // how long each attempt takes
}

func (s *resetCountingStore) ResetCacheRoutingState(ctx context.Context, fingerprint string) error {
	s.resets++
	if s.slow > 0 {
		time.Sleep(s.slow)
	}
	if s.failNext > 0 {
		s.failNext--
		return fmt.Errorf("store unavailable")
	}
	return s.Store.ResetCacheRoutingState(ctx, fingerprint)
}

// deleteHookStore fails the first delete batch after running a hook during
// the failing call: the window in which request-path decisions can fill the
// dirty set before the failed batch is requeued.
type deleteHookStore struct {
	crs.Store
	onFirstDelete func()
	passThrough   bool
}

func (s *deleteHookStore) DeleteCacheHolders(ctx context.Context, keys []crs.HolderKey) error {
	if hook := s.onFirstDelete; hook != nil {
		s.onFirstDelete = nil
		hook()
		if !s.passThrough {
			return fmt.Errorf("store unavailable")
		}
	}
	return s.Store.DeleteCacheHolders(ctx, keys)
}

// A delete is never dropped at the dirty cap: the decision that overflows
// the backlog during a store outage discards the whole durable copy at the
// next flush, so a restart cannot restore the row it condemned, and a
// restore that runs after an overflow resets instead of loading.
func TestDeleteBacklogOverflowResetsDurableCopy(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	st := &resetCountingStore{Store: mem}
	ctx := context.Background()
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	stale := rec("stale", "e", now, time.Minute)
	p.MarkHolderUpsert(stale)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	// The store goes away; deletes fill the budget, and the row's own
	// decision is the one that overflows it: the one a cap would drop.
	for i := 0; i < p.dirtyCap; i++ {
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
	}
	p.MarkHolderDelete(stale.HolderKey(), now.Add(time.Second))
	if s := p.Status(); s.OverflowResets != 1 || s.DroppedDirty != 0 {
		t.Fatalf("an overflowing delete backlog must schedule a reset, not drop: %+v", s)
	}
	p.mu.Lock()
	queued, pending := len(p.holderDeletes), p.resetPending
	p.mu.Unlock()
	if queued != 1 || !pending {
		t.Fatalf("the overflow must release the backlog and queue the new decision: queued=%d pending=%v", queued, pending)
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 || st.resets != 1 {
		t.Fatalf("the reset must remove the row the overflowing delete condemned: rows=%+v resets=%d", rows, st.resets)
	}
	fresh := rec("fresh", "e", now.Add(2*time.Second), time.Minute)
	p.MarkHolderUpsert(fresh)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 1 || rows[0].Key != "fresh" || st.resets != 1 {
		t.Fatalf("evidence after the reset must be written, without another reset: rows=%+v resets=%d", rows, st.resets)
	}
	// An overflow before any restore succeeded, the seeded row's own
	// decision overflowing: the restore resets instead of loading the row.
	seeded := rec("seeded", "e", now.Add(2*time.Second), time.Minute)
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{seeded}); err != nil {
		t.Fatal(err)
	}
	next := New(st, nil, Options{MaxPending: 2})
	for i := 0; i < next.dirtyCap; i++ {
		next.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("x%03d", i), CacheEpoch: "e"}, now.Add(3*time.Second))
	}
	next.MarkHolderDelete(seeded.HolderKey(), now.Add(3*time.Second))
	restoreForTest(t, next, now)
	if s := next.Status(); s.RestoredHolders != 0 || s.OverflowResets != 1 || !s.Ready || st.resets != 2 {
		t.Fatalf("a restore after an overflow must reset, not load: %+v resets=%d", s, st.resets)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 {
		t.Fatalf("the restore-time reset must empty the store: %+v", rows)
	}
	if err := next.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	next.mu.Lock()
	pending = next.resetPending
	next.mu.Unlock()
	if s := next.Status(); st.resets != 2 || pending || s.FlushErrors != 0 {
		t.Fatalf("the restore-time reset must not be repeated by the flush: resets=%d pending=%v %+v", st.resets, pending, s)
	}
}

// A flush whose reset leaves nothing to drain still counts as a flush, so
// a reset-only flush is visible in the health counters.
func TestResetOnlyFlushIsCounted(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	for i := 0; i <= p.dirtyCap; i++ { // the last one overflows
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
	}
	// The overflowing decision is drained with the reset's flush; a second
	// flush with a reset and nothing behind it must still be counted.
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	p.resetPending = true
	p.mu.Unlock()
	before := p.Status()
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if s := p.Status(); s.Flushes != before.Flushes+1 || s.LastFlushAt == "" {
		t.Fatalf("a reset-only flush must be counted: before=%+v after=%+v", before, s)
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

// upsertHookStore runs a hook during the first upsert batch (the window in
// which the batch is in flight) and then fails it, or lets it through when
// passThrough is set.
type upsertHookStore struct {
	crs.Store
	onFirstUpsert func()
	passThrough   bool
}

func (s *upsertHookStore) UpsertCacheHolders(ctx context.Context, rows []crs.HolderRecord) error {
	if hook := s.onFirstUpsert; hook != nil {
		s.onFirstUpsert = nil
		hook()
		if !s.passThrough {
			return fmt.Errorf("store unavailable")
		}
	}
	return s.Store.UpsertCacheHolders(ctx, rows)
}

// An overflow that lands after the drain, while the batch is being written,
// stops the flush before its next upsert chunk: the remainder is requeued
// with its upserts dropped, and the reset runs in that same flush.
func TestFlushStopsWritingUpsertsWhenTheBacklogOverflowsAfterTheDrain(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	hook := &upsertHookStore{Store: mem, passThrough: true}
	st := &resetCountingStore{Store: hook}
	ctx := context.Background()
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 200}) // dirty cap 800: room for two chunks of upserts
	restoreForTest(t, p, now)
	const n = crs.BatchRows + 1 // two chunks
	for i := 0; i < n; i++ {
		p.MarkHolderUpsert(rec(fmt.Sprintf("u%04d", i), "e", now, time.Minute))
	}
	hook.onFirstUpsert = func() {
		// During the first chunk's write: the backlog overflows.
		for i := 0; i <= p.dirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	pending, queued := p.resetPending, len(p.holderUpserts)
	p.mu.Unlock()
	rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0)
	if s := p.Status(); len(rows) != 0 || st.resets != 1 || pending || queued != 0 || s.DroppedDirty != n-crs.BatchRows || s.FlushErrors != 0 {
		t.Fatalf("an overflow after the drain must stop the writes, drop the remainder and reset in the same flush: rows=%d resets=%d pending=%v queued=%d %+v", len(rows), st.resets, pending, queued, s)
	}
}

// An upsert drained before a backlog overflow is not requeued after it: its
// row may be one a released decision condemned, and the reset that follows
// would write it back.
func TestUpsertsDrainedBeforeAnOverflowAreNotRequeued(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	st := &upsertHookStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	condemned := rec("condemned", "e", now, time.Minute)
	p.MarkHolderUpsert(condemned)
	st.onFirstUpsert = func() {
		// While the batch is in flight: the row is invalidated, then the
		// backlog overflows and releases that decision.
		p.MarkHolderDelete(condemned.HolderKey(), now.Add(time.Second))
		for i := 0; i < p.dirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	if err := p.Flush(ctx); err == nil {
		t.Fatal("the first upsert batch must fail")
	}
	p.mu.Lock()
	_, requeued := p.holderUpserts[condemned.HolderKey()]
	p.mu.Unlock()
	if s := p.Status(); requeued || s.DroppedDirty != 1 || s.OverflowResets != 1 {
		t.Fatalf("an upsert drained before the overflow must not be requeued: requeued=%v %+v", requeued, s)
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 {
		t.Fatalf("the condemned row must not be written back after the reset: %+v", rows)
	}
}

// A batch drained after an overflow was handled is requeued in full on a
// later failure: the fence keys on the overflow count the batch was drained
// under, not on whether an overflow ever happened.
func TestUpsertsDrainedAfterAHandledOverflowAreRequeued(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	st := &upsertHookStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	for i := 0; i <= p.dirtyCap; i++ { // the last one overflows
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
	}
	if err := p.Flush(ctx); err != nil { // the reset lands
		t.Fatal(err)
	}
	live := rec("live", "e", now.Add(2*time.Second), time.Minute)
	p.MarkHolderUpsert(live)
	st.onFirstUpsert = func() {} // the batch fails with no overflow in flight
	if err := p.Flush(ctx); err == nil {
		t.Fatal("the upsert batch must fail")
	}
	p.mu.Lock()
	_, requeued := p.holderUpserts[live.HolderKey()]
	p.mu.Unlock()
	if s := p.Status(); !requeued || s.DroppedDirty != 0 {
		t.Fatalf("a batch drained after the handled overflow must be requeued: requeued=%v %+v", requeued, s)
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 1 || rows[0].Key != "live" {
		t.Fatalf("the requeued upsert must reach the store: %+v", rows)
	}
}

// A drain never proceeds while a reset is pending: the check and the drain
// share one lock hold, so nothing drained after an overflow can be written
// before the reset.
func TestDrainRefusesWhileAResetIsPending(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	p.MarkHolderUpsert(rec("live", "e", now, time.Minute))
	for i := 0; i <= p.dirtyCap; i++ { // the last one overflows
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
	}
	b, pending := p.drainUnlessReset()
	if !pending || len(b.upserts) != 0 || len(b.deletes) != 0 {
		t.Fatalf("a pending reset must refuse the drain: pending=%v upserts=%d deletes=%d", pending, len(b.upserts), len(b.deletes))
	}
	p.mu.Lock()
	upserts, deletes := len(p.holderUpserts), len(p.holderDeletes)
	p.mu.Unlock()
	if upserts != 1 || deletes != 1 {
		t.Fatalf("a refused drain must leave the dirty sets intact: upserts=%d deletes=%d", upserts, deletes)
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if b, pending := p.drainUnlessReset(); pending || len(b.upserts) != 0 {
		t.Fatalf("after the reset the flush must have drained and written the batch: pending=%v upserts=%d", pending, len(b.upserts))
	}
}

// An overflow that lands between a flush's reset check and its drain is
// reset by that same flush: the drain refuses, the reset runs, and only
// then is anything written.
func TestFlushResetsWhenTheBacklogOverflowsAfterTheCheck(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	st := &resetCountingStore{Store: mem}
	ctx := context.Background()
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 2, Fingerprint: "fp"}) // dirty cap 8
	restoreForTest(t, p, now)                                    // records the generation: one reset
	base := st.resets
	condemned := rec("condemned", "e", now, time.Minute)
	p.MarkHolderUpsert(condemned)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.beforeDrain = func() {
		p.beforeDrain = nil
		// The row's decision is released by the overflow the fillers cause.
		p.MarkHolderDelete(condemned.HolderKey(), now.Add(time.Second))
		for i := 0; i < p.dirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	pending := p.resetPending
	p.mu.Unlock()
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 || st.resets != base+1 || pending {
		t.Fatalf("an overflow after the check must be reset by the same flush: rows=%+v resets=%d pending=%v", rows, st.resets, pending)
	}
	if fp, _ := mem.CacheRoutingKeyFingerprint(ctx); fp != "fp" {
		t.Fatalf("the reset must have recorded the generation: %q", fp)
	}
}

// The fence runs before every store call, not only before upsert chunks: a
// delete-only batch stops at its next chunk when the backlog overflowed
// since the drain, the remainder is requeued and the reset lands in that
// same flush.
func TestFlushStopsWritingDeletesWhenTheBacklogOverflowsAfterTheDrain(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	hook := &deleteHookStore{Store: mem, passThrough: true}
	st := &resetCountingStore{Store: hook}
	ctx := context.Background()
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 200}) // dirty cap 800: room for two chunks of deletes
	restoreForTest(t, p, now)
	const n = crs.BatchRows + 1 // two chunks
	for i := 0; i < n; i++ {
		p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("g%04d", i), CacheEpoch: "e"}, now)
	}
	hook.onFirstDelete = func() {
		// During the first chunk's write: fresh decisions overflow the
		// backlog the drain had just emptied.
		for i := 0; i <= p.dirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	pending, queued := p.resetPending, len(p.holderDeletes)
	p.mu.Unlock()
	if s := p.Status(); st.resets != 1 || pending || s.RowsDeleted != crs.BatchRows || queued != 2 || s.FlushErrors != 0 {
		t.Fatalf("an overflow during a delete-only batch must stop at the next chunk, requeue it and reset in the same flush: resets=%d pending=%v queued=%d %+v", st.resets, pending, queued, s)
	}
}

// A reset that fails on the mid-flush path is counted once against that
// flush and retried by the next, which then writes the requeued deletes.
func TestFlushRetriesAFailedResetAfterAMidFlushOverflow(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	hook := &upsertHookStore{Store: mem, passThrough: true}
	st := &resetCountingStore{Store: hook}
	ctx := context.Background()
	now := time.Now()
	p := New(st, nil, Options{MaxPending: 200}) // dirty cap 800
	restoreForTest(t, p, now)
	gone := rec("gone", "e", now, time.Minute)
	p.MarkHolderUpsert(gone)
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.MarkHolderDelete(gone.HolderKey(), now.Add(time.Second))
	const n = crs.BatchRows + 1 // two chunks of upserts ahead of the delete
	for i := 0; i < n; i++ {
		p.MarkHolderUpsert(rec(fmt.Sprintf("u%04d", i), "e", now.Add(time.Second), time.Minute))
	}
	hook.onFirstUpsert = func() {
		for i := 0; i <= p.dirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(2*time.Second))
		}
		st.failNext = 1 // the reset this flush attempts fails, slowly
		st.slow = 30 * time.Millisecond
	}
	stamped := p.Status().LastFlushAt
	if err := p.Flush(ctx); err == nil {
		t.Fatal("a failed reset must fail the flush")
	}
	p.mu.Lock()
	pending := p.resetPending
	_, requeued := p.holderDeletes[gone.HolderKey()]
	p.mu.Unlock()
	// The reset is part of the flush: its duration lands in the stamp.
	if s := p.Status(); st.resets != 1 || !pending || !requeued || s.Flushes != 2 || s.FlushErrors != 1 || s.LastFlushAt < stamped || s.LastFlushMs < 30 {
		t.Fatalf("a failed mid-flush reset must be counted once and leave the reset pending with the delete requeued: resets=%d pending=%v requeued=%v %+v", st.resets, pending, requeued, s)
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	p.mu.Lock()
	pending = p.resetPending
	p.mu.Unlock()
	rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0)
	if s := p.Status(); st.resets != 2 || pending || len(rows) != 0 || s.RowsDeleted == 0 || s.FlushErrors != 1 {
		t.Fatalf("the next flush must reset and write the requeued deletes: resets=%d pending=%v rows=%d %+v", st.resets, pending, len(rows), s)
	}
}

// An overflow wakes the flush loop once, however many overflows pile up
// before it runs, and never blocks the mark.
func TestOverflowWakesTheFlushLoop(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	now := time.Now()
	p := New(mem, nil, Options{MaxPending: 2}) // dirty cap 8
	select {
	case <-p.Wake():
		t.Fatal("no wake-up before an overflow")
	default:
	}
	for round := 0; round < 2; round++ { // two overflows, one token
		for i := 0; i <= p.dirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("r%d-%03d", round, i), CacheEpoch: "e"}, now)
		}
	}
	select {
	case <-p.Wake():
	default:
		t.Fatal("an overflow must wake the flush loop")
	}
	select {
	case <-p.Wake():
		t.Fatal("overflows before the loop ran must coalesce into one wake-up")
	default:
	}
	if s := p.Status(); s.OverflowResets != 2 {
		t.Fatalf("both overflows must be counted: %+v", s)
	}
}

// A delete requeued by a failed flush is never dropped either, even when
// request-path decisions filled the dirty set during the failing write.
func TestRequeuedDeleteIsNeverDroppedAtTheCap(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	ctx := context.Background()
	now := time.Now()
	st := &deleteHookStore{Store: mem}
	p := New(st, nil, Options{MaxPending: 2}) // dirty cap 8
	restoreForTest(t, p, now)
	victim := rec("victim", "e", now, time.Minute)
	if err := mem.UpsertCacheHolders(ctx, []crs.HolderRecord{victim}); err != nil {
		t.Fatal(err)
	}
	p.MarkHolderDelete(victim.HolderKey(), now.Add(time.Second))
	st.onFirstDelete = func() {
		for i := 0; i < p.dirtyCap; i++ {
			p.MarkHolderDelete(crs.HolderKey{Key: fmt.Sprintf("d%03d", i), CacheEpoch: "e"}, now.Add(time.Second))
		}
	}
	if err := p.Flush(ctx); err == nil {
		t.Fatal("the first delete batch must fail")
	}
	p.mu.Lock()
	queued := len(p.holderDeletes)
	_, requeued := p.holderDeletes[victim.HolderKey()]
	p.mu.Unlock()
	if s := p.Status(); !requeued || queued != p.dirtyCap+1 || s.DroppedDirty != 0 || s.OverflowResets != 0 {
		t.Fatalf("a requeued delete must be kept past the cap: requeued=%v queued=%d %+v", requeued, queued, s)
	}
	if err := p.Flush(ctx); err != nil {
		t.Fatal(err)
	}
	if rows, _ := mem.LoadCacheHolders(ctx, now, time.Minute, 0); len(rows) != 0 {
		t.Fatalf("the requeued delete must reach the store: %+v", rows)
	}
}

// Timestamp ties go to the delete decision, whether pending or retained.
func TestDeleteDecisionWinsTimestampTies(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	p := New(mem, nil, Options{MaxPending: 10})
	now := time.Now()
	restoreForTest(t, p, now)
	k := crs.HolderKey{Key: "a", CacheEpoch: "e"}
	p.MarkHolderDelete(k, now)
	same := rec("a", "e", now, time.Minute) // sampled the same clock value
	p.MarkHolderUpsert(same)
	if b := p.drain(); len(b.deletes) != 1 || len(b.upserts) != 0 {
		t.Fatalf("an equal-time receipt must not cancel the decision: %+v %+v", b.deletes, b.upserts)
	}
	if !p.Tombstoned(k, now) {
		t.Fatal("an equal-time row is tombstoned while the delete is in flight")
	}
	if err := p.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !p.Tombstoned(k, now) {
		t.Fatal("an equal-time row is tombstoned after the delete was written")
	}
	p.MarkHolderUpsert(same)
	if !p.dirtyEmpty() {
		t.Fatal("an equal-time receipt must not be queued after the delete was written")
	}
	if p.Tombstoned(k, now.Add(time.Nanosecond)) {
		t.Fatal("evidence strictly after the decision is not tombstoned")
	}
}
