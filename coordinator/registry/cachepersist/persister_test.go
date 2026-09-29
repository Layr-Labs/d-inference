package cachepersist

import (
	"context"
	"errors"
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
	if rows := p.Take("e1", "other-model"); rows != nil {
		t.Fatalf("another model must not take the rows: %+v", rows)
	}
	p.prunePending(now)
	if s := p.Status(); s.PendingHolders != 1 || s.DroppedPending != 2 {
		t.Fatalf("prune must drop the expired row: %+v", s)
	}
	rows := p.Take("e1", "model")
	if len(rows) != 1 || rows[0].Key != "a" || p.HasPending() {
		t.Fatalf("take: %+v", rows)
	}
	p.AddBound(1, 0)
	// A capability that is gone: the registry takes the rows, settles each
	// durable row (here: delete) and reports them dropped.
	p.Park(rec("d", "e2", now, time.Minute))
	for _, r := range p.Take("e2", "model") {
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
	rows := p.Take("e", "model")
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
	if rows := p2.Take("e", "model"); len(rows) != 1 || rows[0].Key != "fresh" {
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
	if got := p.Take("e", "model"); len(got) != 1 || got[0].Key != "valid" || !got[0].ExpiresAt.Equal(now.Add(24*time.Minute)) {
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
	rows := p.Take("e", "model")
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
	rows := p.Take("e", "model")
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
	rows := p.Take("e", "model")
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
	n, order := len(p.recentDeletes), len(p.recentOrder)
	p.mu.Unlock()
	if n != 3 || order != 3 {
		t.Fatalf("retention must stay within the holder budget: map=%d order=%d", n, order)
	}
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
	n = len(p.recentDeletes)
	p.compactRecentOrderLocked()
	order = len(p.recentOrder)
	p.mu.Unlock()
	if n != 3 || order != 3 {
		t.Fatalf("retention must stay within the holder budget after refreshes: map=%d order=%d", n, order)
	}
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
