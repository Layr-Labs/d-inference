package api

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// faultingTelemetryStore layers injectable batch errors / panics and a
// per-row panic onto countingTelemetryStore (which still applies every
// successful call to a real memory store).
type faultingTelemetryStore struct {
	*countingTelemetryStore

	mu          sync.Mutex
	batchErr    error  // returned by both batch methods when non-nil
	panicBatch  bool   // both batch methods panic
	panicRecord string // RecordInferenceRoute panics for this request id
}

func newFaultingTelemetryStore() *faultingTelemetryStore {
	return &faultingTelemetryStore{countingTelemetryStore: newCountingTelemetryStore()}
}

// waitForCalls polls until the store has seen n calls with the given log
// prefix. The failure-policy tests size their groups to fill by count so the
// group executes while the sink is still OPEN (a close-time execution would
// take the closing branch instead), then observe the resulting store calls.
func waitForCalls(t *testing.T, st *countingTelemetryStore, prefix string, n int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if calls, _ := st.count(prefix); calls >= n {
			return
		}
		time.Sleep(time.Millisecond)
	}
	calls, _ := st.count(prefix)
	t.Fatalf("waited for %d %q calls, saw %d; log=%v", n, prefix, calls, st.callLog())
}

// waitForDrops polls until the sink's drop counter reaches n.
func waitForDrops(t *testing.T, sink *telemetrySink, n int64) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if sink.dropped.Load() >= n {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("waited for dropped >= %d, got %d", n, sink.dropped.Load())
}

func (f *faultingTelemetryStore) fault() (error, bool, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.batchErr, f.panicBatch, f.panicRecord
}

func (f *faultingTelemetryStore) RecordInferenceRoutes(rs []*store.InferenceRouteRecord) error {
	f.note(fmt.Sprintf("records:%d", len(rs)))
	err, panics, _ := f.fault()
	if panics {
		panic("injected batch panic")
	}
	if err != nil {
		return err
	}
	return f.MemoryStore.RecordInferenceRoutes(rs)
}

func (f *faultingTelemetryStore) RecordInferenceRoute(r *store.InferenceRouteRecord) error {
	if _, _, id := f.fault(); id != "" && r.RequestID == id {
		f.note("record")
		panic("injected row panic")
	}
	return f.countingTelemetryStore.RecordInferenceRoute(r)
}

func (f *faultingTelemetryStore) UpdateInferenceRouteOutcomes(us []store.InferenceRouteOutcomeUpdate) error {
	f.note(fmt.Sprintf("updates:%d", len(us)))
	err, panics, _ := f.fault()
	if panics {
		panic("injected batch panic")
	}
	if err != nil {
		return err
	}
	return f.MemoryStore.UpdateInferenceRouteOutcomes(us)
}

func TestCrossesPowerOfTen(t *testing.T) {
	cases := []struct {
		before, after int64
		want          bool
	}{
		{0, 0, false}, {0, 1, true}, {1, 2, false}, {9, 10, true}, {10, 11, false},
		{5, 12, true}, {99, 100, true}, {100, 1000, true}, {101, 999, false}, {0, 256, true},
	}
	for _, tc := range cases {
		if got := crossesPowerOfTen(tc.before, tc.after); got != tc.want {
			t.Fatalf("crossesPowerOfTen(%d, %d) = %v, want %v", tc.before, tc.after, got, tc.want)
		}
	}
}

func TestTelemetrySinkClampsWorkersToOne(t *testing.T) {
	sink := newBatchingTelemetrySink(quietLogger(), 8, 4, 256, time.Second)
	defer sink.closeAndWait(time.Second)
	if sink.workerCount != 1 {
		t.Fatalf("workerCount = %d, want 1 (ordering depends on a single consumer)", sink.workerCount)
	}
	if got := newTelemetrySink(quietLogger(), 8, 0); got.workerCount != 1 {
		t.Fatalf("default workers = %d, want 1", got.workerCount)
	}
}

func TestTelemetrySinkRejectsSubmitsAfterClose(t *testing.T) {
	st := newCountingTelemetryStore()
	sink := newTestSink(t, st, 1024, 256, 10*time.Second)
	mustCloseAndWait(t, sink)

	if sink.submitRoute(routeRec("late-1", 1, "p")) {
		t.Fatal("submitRoute after close must be rejected")
	}
	if sink.submitOutcome("late-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"}) {
		t.Fatal("submitOutcome after close must be rejected")
	}
	if sink.submit(func() {}) {
		t.Fatal("submit after close must be rejected")
	}
	if got := sink.dropped.Load(); got != 3 {
		t.Fatalf("dropped = %d, want 3 (every post-close submit counts)", got)
	}
	if len(sink.ch) != 0 {
		t.Fatalf("post-close submits must not enter the buffer: %d buffered", len(sink.ch))
	}
	if st.route("late-1", 1) != nil {
		t.Fatal("post-close submit must not be persisted")
	}
}

// TestTelemetrySinkTransientBatchFailureDropsGroup: a batch that fails because
// the store is unavailable (deadline, connection, closed pool) is dropped and
// counted — never replayed row by row.
func TestTelemetrySinkTransientBatchFailureDropsGroup(t *testing.T) {
	st := newFaultingTelemetryStore()
	st.batchErr = fmt.Errorf("store: record inference routes (5 rows): %w", context.DeadlineExceeded)
	const n = 5
	// Groups fill by size (n) so each executes while the sink is open.
	sink := newTestSink(t, st, 1024, n, 10*time.Second)

	for i := 0; i < n; i++ {
		sink.submitRoute(routeRec(fmt.Sprintf("tr-%d", i), 1, "p"))
	}
	for i := 0; i < n; i++ {
		sink.submitOutcome(fmt.Sprintf("tr-%d", i), 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"})
	}
	waitForDrops(t, sink, 2*n)
	flushAndWait(t, sink)

	if calls, _ := st.count("record"); calls != 0 {
		t.Fatalf("transient failure must not replay rows: %d single record writes, log=%v", calls, st.callLog())
	}
	if calls, _ := st.count("update"); calls != 0 {
		t.Fatalf("transient failure must not replay updates: %d single update writes, log=%v", calls, st.callLog())
	}
	if got := sink.dropped.Load(); got != 2*n {
		t.Fatalf("dropped = %d, want %d (records + updates)", got, 2*n)
	}
	if st.route("tr-0", 1) != nil {
		t.Fatal("nothing must be persisted")
	}
}

// TestTelemetrySinkClosingDrainDoesNotReplayRows: once close has been called
// the pool is about to go away, so even a row-fault-shaped batch error must
// not fan out into N per-row attempts (each of which would log an error).
func TestTelemetrySinkClosingDrainDoesNotReplayRows(t *testing.T) {
	st := newCountingTelemetryStore()
	st.failBatchRecords.Store(true)
	sink := newTestSink(t, st, 1024, 256, 10*time.Second)

	const n = 5
	for i := 0; i < n; i++ {
		sink.submitRoute(routeRec(fmt.Sprintf("cd-%d", i), 1, "p"))
	}
	// The window never fires, so the group (all n ops, once the worker holds
	// them) is executed by the close-time drain — i.e. after done is closed.
	flushAndWait(t, sink)

	if calls, _ := st.count("record"); calls != 0 {
		t.Fatalf("closing drain must not replay rows: %d single writes, log=%v", calls, st.callLog())
	}
	if got := sink.dropped.Load(); got != n {
		t.Fatalf("dropped = %d, want %d", got, n)
	}
}

// TestTelemetrySinkBatchPanicReplaysRowsWithIsolation: a panic inside the
// batch call is a failed batch (replayed row by row while open), and a panic
// inside one replayed row does not take its neighbours or the worker down.
func TestTelemetrySinkBatchPanicReplaysRowsWithIsolation(t *testing.T) {
	st := newFaultingTelemetryStore()
	st.panicBatch = true
	st.panicRecord = "pp-2"
	const n = 5
	// The group fills by size (n) so it executes while the sink is open.
	sink := newTestSink(t, st, 1024, n, 10*time.Second)

	for i := 0; i < n; i++ {
		sink.submitRoute(routeRec(fmt.Sprintf("pp-%d", i), 1, "p"))
	}
	waitForCalls(t, st.countingTelemetryStore, "record", n)
	flushAndWait(t, sink)

	if calls, _ := st.count("records"); calls != 1 {
		t.Fatalf("batch must be attempted once, got %d; log=%v", calls, st.callLog())
	}
	if calls, _ := st.count("record"); calls != n {
		t.Fatalf("every row must be replayed after a batch panic: %d single writes, log=%v", calls, st.callLog())
	}
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("pp-%d", i)
		rec := st.route(id, 1)
		if i == 2 {
			if rec != nil {
				t.Fatalf("panicking row must not be written: %+v", rec)
			}
			continue
		}
		if rec == nil {
			t.Fatalf("row %s must survive its neighbour's panic", id)
		}
	}
}

// TestServerCloseFlushesRouteTelemetryBeforeReturning covers the production
// shutdown path: Server.Close waits (bounded) for the sink's final drain, so
// rows are in the store when Close returns — before main closes the pool —
// and anything submitted afterwards is rejected and counted.
func TestServerCloseFlushesRouteTelemetryBeforeReturning(t *testing.T) {
	srv, st := testServer(t)
	srv.submitRouteRecord(routeRec("shut-1", 1, "p"))
	srv.updateInferenceRouteOutcomeWithModel("shut-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: 2, CompletionTokensSet: true})

	srv.Close()

	var found *store.InferenceRouteRecord
	for _, r := range st.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == "shut-1" {
			rec := r
			found = &rec
		}
	}
	if found == nil || found.FinalStatus != "success" || found.CompletionTokens != 2 {
		t.Fatalf("Close must flush the buffered route record and its outcome before returning: %+v", found)
	}

	srv.submitRouteRecord(routeRec("shut-2", 1, "p"))
	if got := srv.routeTelemetry.dropped.Load(); got != 1 {
		t.Fatalf("post-Close submit must be rejected and counted: dropped=%d", got)
	}
	for _, r := range st.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == "shut-2" {
			t.Fatal("post-Close submit must not be persisted")
		}
	}
}

// TestTelemetrySinkCloseIsBoundedByStuckStore: a store call that never returns
// cannot hold closeAndWait past its deadline.
func TestTelemetrySinkCloseIsBoundedByStuckStore(t *testing.T) {
	st := newCountingTelemetryStore()
	st.gate = make(chan struct{})
	sink := newBatchingTelemetrySink(quietLogger(), 8, 1, 1, time.Millisecond)
	sink.bind(st)
	sink.submitRoute(routeRec("stuck-1", 1, "p"))

	start := time.Now()
	if sink.closeAndWait(50 * time.Millisecond) {
		t.Fatal("closeAndWait must report a timeout while the store is stuck")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("closeAndWait took %v, want ~50ms", elapsed)
	}
	close(st.gate)
	if !sink.closeAndWait(time.Second) {
		t.Fatal("worker must exit once the store unblocks")
	}
}
