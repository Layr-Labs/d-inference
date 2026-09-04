package api

import (
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// countingTelemetryStore wraps a REAL memory store: every call is applied to
// it (so row state is asserted through the real reader) while the wrapper
// records which store method the sink chose and in what order.
type countingTelemetryStore struct {
	*store.MemoryStore

	mu    sync.Mutex
	calls []string // "record", "records:N", "update", "updates:N", "fn"

	failBatchRecords atomic.Bool
	failBatchUpdates atomic.Bool
	// gate, when non-nil, blocks every single-record write until it is closed
	// (simulates a stuck store while the worker holds one op).
	gate chan struct{}
}

func newCountingTelemetryStore() *countingTelemetryStore {
	return &countingTelemetryStore{MemoryStore: store.NewMemory(store.Config{})}
}

func (c *countingTelemetryStore) note(call string) {
	c.mu.Lock()
	c.calls = append(c.calls, call)
	c.mu.Unlock()
}

func (c *countingTelemetryStore) callLog() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]string(nil), c.calls...)
}

func (c *countingTelemetryStore) count(prefix string) (calls, rows int) {
	for _, call := range c.callLog() {
		var n int
		if call == prefix {
			calls++
			rows++
			continue
		}
		if _, err := fmt.Sscanf(call, prefix+":%d", &n); err == nil {
			calls++
			rows += n
		}
	}
	return calls, rows
}

func (c *countingTelemetryStore) RecordInferenceRoute(r *store.InferenceRouteRecord) error {
	if c.gate != nil {
		<-c.gate
	}
	c.note("record")
	return c.MemoryStore.RecordInferenceRoute(r)
}

func (c *countingTelemetryStore) RecordInferenceRoutes(rs []*store.InferenceRouteRecord) error {
	c.note(fmt.Sprintf("records:%d", len(rs)))
	if c.failBatchRecords.Load() {
		return errors.New("injected batch insert failure")
	}
	return c.MemoryStore.RecordInferenceRoutes(rs)
}

func (c *countingTelemetryStore) UpdateInferenceRouteOutcome(id string, attempt int, o *store.InferenceRouteOutcome) error {
	c.note("update")
	return c.MemoryStore.UpdateInferenceRouteOutcome(id, attempt, o)
}

func (c *countingTelemetryStore) UpdateInferenceRouteOutcomes(us []store.InferenceRouteOutcomeUpdate) error {
	c.note(fmt.Sprintf("updates:%d", len(us)))
	if c.failBatchUpdates.Load() {
		return errors.New("injected batch update failure")
	}
	return c.MemoryStore.UpdateInferenceRouteOutcomes(us)
}

func (c *countingTelemetryStore) route(id string, attempt int) *store.InferenceRouteRecord {
	for _, r := range c.InferenceRouteRecordsSince(time.Time{}) {
		if r.RequestID == id && r.Attempt == attempt {
			rec := r
			return &rec
		}
	}
	return nil
}

func routeRec(id string, attempt int, provider string) *store.InferenceRouteRecord {
	return &store.InferenceRouteRecord{RequestID: id, Attempt: attempt, ProviderID: provider, Outcome: "selected", Model: "m"}
}

// newTestSink returns a bound sink with a window long enough that a group only
// ends by size, conflict, or close — making grouping deterministic.
func newTestSink(t *testing.T, st store.TelemetryStore, capacity, maxBatch int, window time.Duration) *telemetrySink {
	t.Helper()
	sink := newBatchingTelemetrySink(quietLogger(), capacity, 1, maxBatch, window)
	sink.bind(st)
	t.Cleanup(func() { sink.closeAndWait(5 * time.Second) })
	return sink
}

func mustCloseAndWait(t *testing.T, sink *telemetrySink) {
	t.Helper()
	if !sink.closeAndWait(5 * time.Second) {
		t.Fatal("sink worker did not stop after close")
	}
}

// flushAndWait waits until the worker has pulled every buffered op into its
// current group (the test sinks use a window long enough that a group only
// ends by size, conflict, or close), then closes so that group is written.
// Closing earlier lets the close race the gather and split the group — correct
// behaviour, but it makes exact grouping assertions timing-dependent.
func flushAndWait(t *testing.T, sink *telemetrySink) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for len(sink.ch) != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if len(sink.ch) != 0 {
		t.Fatalf("worker did not drain the queue: %d ops still buffered", len(sink.ch))
	}
	mustCloseAndWait(t, sink)
}

func TestTelemetrySinkCoalescesRecordsAndUpdates(t *testing.T) {
	st := newCountingTelemetryStore()
	sink := newTestSink(t, st, 1024, 256, 10*time.Second)

	const n = 20
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("req-%d", i)
		if !sink.submitRoute(routeRec(id, 1, "p")) {
			t.Fatalf("submitRoute %d rejected", i)
		}
		// Interleaved: an update for the row just recorded lands in the same
		// group; the insert must still be written first.
		if !sink.submitOutcome(id, 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: i + 1}) {
			t.Fatalf("submitOutcome %d rejected", i)
		}
	}
	// Close flushes the held group (the window never fired).
	flushAndWait(t, sink)

	if calls, rows := st.count("records"); calls != 1 || rows != n {
		t.Fatalf("record batches: calls=%d rows=%d, want 1/%d; log=%v", calls, rows, n, st.callLog())
	}
	if calls, rows := st.count("updates"); calls != 1 || rows != n {
		t.Fatalf("update batches: calls=%d rows=%d, want 1/%d; log=%v", calls, rows, n, st.callLog())
	}
	if c, _ := st.count("record"); c != 0 {
		t.Fatalf("no single-row record writes expected; log=%v", st.callLog())
	}
	if log := st.callLog(); len(log) != 2 || log[0] != fmt.Sprintf("records:%d", n) || log[1] != fmt.Sprintf("updates:%d", n) {
		t.Fatalf("inserts must precede updates: %v", log)
	}
	for i := 0; i < n; i++ {
		rec := st.route(fmt.Sprintf("req-%d", i), 1)
		if rec == nil || rec.FinalStatus != "success" || rec.CompletionTokens != i+1 {
			t.Fatalf("row %d missing or without outcome: %+v", i, rec)
		}
	}
}

func TestTelemetrySinkWindowFlushesQuietQueue(t *testing.T) {
	st := newCountingTelemetryStore()
	sink := newTestSink(t, st, 1024, 256, 30*time.Millisecond)

	sink.submitRoute(routeRec("win-1", 1, "p"))
	sink.submitOutcome("win-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"})

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if rec := st.route("win-1", 1); rec != nil && rec.FinalStatus == "success" {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("group was not flushed by the window; log=%v", st.callLog())
}

func TestTelemetrySinkMaxBatchSplitsGroups(t *testing.T) {
	st := newCountingTelemetryStore()
	sink := newTestSink(t, st, 1024, 4, 10*time.Second)

	for i := 0; i < 10; i++ {
		sink.submitRoute(routeRec(fmt.Sprintf("mb-%d", i), 1, "p"))
	}
	flushAndWait(t, sink)

	if calls, rows := st.count("records"); calls != 3 || rows != 10 {
		t.Fatalf("expected groups of 4/4/2: calls=%d rows=%d log=%v", calls, rows, st.callLog())
	}
	for i := 0; i < 10; i++ {
		if st.route(fmt.Sprintf("mb-%d", i), 1) == nil {
			t.Fatalf("row %d missing", i)
		}
	}
}

// TestTelemetrySinkReRecordKeepsPerKeyOrder is the live dispatch.go pattern:
// the same (request, attempt) is recorded as "queued", updated, then
// re-recorded as "selected" and finalised — all inside one window. The
// re-record must open a new group so inserts-first coalescing cannot hoist it
// above the earlier update.
func TestTelemetrySinkReRecordKeepsPerKeyOrder(t *testing.T) {
	st := newCountingTelemetryStore()
	sink := newTestSink(t, st, 1024, 256, 10*time.Second)

	queued := routeRec("rr-1", 1, "")
	queued.Outcome = "queued"
	sink.submitRoute(queued)
	sink.submitOutcome("rr-1", 1, "m", &store.InferenceRouteOutcome{ActualTTFTMs: 5, UsedBackup: true})
	sink.submitRoute(routeRec("rr-1", 1, "p-final"))
	sink.submitOutcome("rr-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: 9})
	// Unrelated key in the same window: free to coalesce with either group.
	sink.submitRoute(routeRec("rr-2", 1, "p2"))
	flushAndWait(t, sink)

	rec := st.route("rr-1", 1)
	if rec == nil {
		t.Fatal("row missing")
	}
	if rec.ProviderID != "p-final" || rec.Outcome != "selected" {
		t.Fatalf("re-record must win the snapshot: %+v", rec)
	}
	if rec.FinalStatus != "success" || rec.CompletionTokens != 9 || rec.ActualTTFTMs != 5 || !rec.UsedBackup {
		t.Fatalf("both updates must survive in order: %+v", rec)
	}
	if st.route("rr-2", 1) == nil {
		t.Fatal("unrelated row missing")
	}
	// Two groups: [queued, ttft-update, (rr-2 joins group 2)] and
	// [selected, success-update]. The first group's insert is a single record
	// write; the second group's insert is either single or a 2-row batch
	// depending on where rr-2 landed. Total record rows must be 3, and no
	// group may have held two rr-1 inserts.
	singleCalls, singleRows := st.count("record")
	batchCalls, batchRows := st.count("records")
	if singleRows+batchRows != 3 || singleCalls+batchCalls != 2 {
		t.Fatalf("expected two insert groups covering three records: log=%v", st.callLog())
	}
}

// TestTelemetrySinkUpdateBeforeInsertStaysNoOp pins baseline parity for the
// pathological queue order (an update racing ahead of its insert): the update
// is a silent no-op and the insert still lands — coalescing must not "fix" it
// by reordering the insert ahead.
func TestTelemetrySinkUpdateBeforeInsertStaysNoOp(t *testing.T) {
	st := newCountingTelemetryStore()
	sink := newTestSink(t, st, 1024, 256, 10*time.Second)

	sink.submitOutcome("ub-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"})
	sink.submitRoute(routeRec("ub-1", 1, "p"))
	flushAndWait(t, sink)

	rec := st.route("ub-1", 1)
	if rec == nil {
		t.Fatal("row missing")
	}
	if rec.FinalStatus != "" {
		t.Fatalf("update that preceded its insert must not apply: %+v", rec)
	}
	if log := st.callLog(); len(log) != 2 || log[0] != "update" || log[1] != "record" {
		t.Fatalf("queue order must be preserved for a same-key update->insert: %v", log)
	}
}

func TestTelemetrySinkGenericClosureKeepsQueuePosition(t *testing.T) {
	st := newCountingTelemetryStore()
	sink := newTestSink(t, st, 1024, 256, 10*time.Second)

	sink.submitRoute(routeRec("g-1", 1, "p"))
	sink.submitRoute(routeRec("g-2", 1, "p"))
	sink.submitOutcome("g-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"})
	sink.submit(func() { st.note("fn") })
	sink.submitOutcome("g-2", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "error", CompletionTokensSet: true})
	flushAndWait(t, sink)

	want := []string{"records:2", "update", "fn", "update"}
	got := st.callLog()
	if len(got) != len(want) {
		t.Fatalf("call log = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("call log = %v, want %v", got, want)
		}
	}
}

func TestTelemetrySinkDropsAndCountsWhenFull(t *testing.T) {
	st := newCountingTelemetryStore()
	st.gate = make(chan struct{})
	sink := newTestSink(t, st, 2, 1, time.Millisecond)

	// Op 1 is taken by the worker and blocks in the store; ops 2 and 3 fill
	// the buffer; op 4 must be dropped without blocking.
	if !sink.submitRoute(routeRec("d-1", 1, "p")) {
		t.Fatal("op 1 rejected")
	}
	deadline := time.Now().Add(2 * time.Second)
	for len(sink.ch) != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if !sink.submitRoute(routeRec("d-2", 1, "p")) || !sink.submitRoute(routeRec("d-3", 1, "p")) {
		t.Fatal("ops 2/3 should fit the buffer")
	}
	done := make(chan bool, 1)
	go func() { done <- sink.submitRoute(routeRec("d-4", 1, "p")) }()
	select {
	case accepted := <-done:
		if accepted {
			t.Fatal("op 4 must be dropped when the buffer is full")
		}
	case <-time.After(time.Second):
		t.Fatal("submit blocked on a full buffer")
	}
	if got := sink.dropped.Load(); got != 1 {
		t.Fatalf("dropped = %d, want 1", got)
	}

	close(st.gate)
	mustCloseAndWait(t, sink)
	for _, id := range []string{"d-1", "d-2", "d-3"} {
		if st.route(id, 1) == nil {
			t.Fatalf("accepted op %s must be written", id)
		}
	}
	if st.route("d-4", 1) != nil {
		t.Fatal("dropped op must not be written")
	}
}

func TestTelemetrySinkCloseFlushesBufferedOps(t *testing.T) {
	st := newCountingTelemetryStore()
	sink := newTestSink(t, st, 1024, 256, 10*time.Second)

	const n = 300 // more than one group: the close-time drain must loop
	for i := 0; i < n; i++ {
		sink.submitRoute(routeRec(fmt.Sprintf("cf-%d", i), 1, "p"))
	}
	for i := 0; i < n; i++ {
		sink.submitOutcome(fmt.Sprintf("cf-%d", i), 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"})
	}
	// Close while ops are still buffered: the worker's close-time drain must
	// write them (in groups) before it exits.
	mustCloseAndWait(t, sink)

	for i := 0; i < n; i++ {
		rec := st.route(fmt.Sprintf("cf-%d", i), 1)
		if rec == nil || rec.FinalStatus != "success" {
			t.Fatalf("row %d not flushed on close: %+v", i, rec)
		}
	}
	// close is idempotent and a second closeAndWait returns immediately.
	if !sink.closeAndWait(time.Second) {
		t.Fatal("second closeAndWait must not block")
	}
}

func TestTelemetrySinkBatchFailureFallsBackToSingleWrites(t *testing.T) {
	st := newCountingTelemetryStore()
	st.failBatchRecords.Store(true)
	st.failBatchUpdates.Store(true)
	const n = 5
	// Groups fill by size (n) so each executes while the sink is OPEN — the
	// per-row replay is only taken while open; a closing drain drops instead.
	sink := newTestSink(t, st, 1024, n, 10*time.Second)

	for i := 0; i < n; i++ {
		sink.submitRoute(routeRec(fmt.Sprintf("fb-%d", i), 1, "p"))
	}
	waitForCalls(t, st, "record", n)
	for i := 0; i < n; i++ {
		sink.submitOutcome(fmt.Sprintf("fb-%d", i), 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"})
	}
	waitForCalls(t, st, "update", n)
	flushAndWait(t, sink)

	if calls, _ := st.count("records"); calls != 1 {
		t.Fatalf("batch insert should be attempted once, got %d", calls)
	}
	if calls, _ := st.count("record"); calls != n {
		t.Fatalf("every record must be retried individually: got %d single writes, log=%v", calls, st.callLog())
	}
	if calls, _ := st.count("update"); calls != n {
		t.Fatalf("every update must be retried individually: got %d single writes, log=%v", calls, st.callLog())
	}
	for i := 0; i < n; i++ {
		rec := st.route(fmt.Sprintf("fb-%d", i), 1)
		if rec == nil || rec.FinalStatus != "success" {
			t.Fatalf("row %d must be written by the fallback: %+v", i, rec)
		}
	}
}

func TestTelemetrySinkPanicInOneUnitDoesNotSkipTheRest(t *testing.T) {
	st := newCountingTelemetryStore()
	sink := newTestSink(t, st, 1024, 256, 10*time.Second)

	sink.submitRoute(routeRec("pn-1", 1, "p"))
	sink.submit(func() { panic("telemetry closure panic") })
	sink.submitOutcome("pn-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"})
	flushAndWait(t, sink)

	if rec := st.route("pn-1", 1); rec == nil || rec.FinalStatus != "success" {
		t.Fatalf("units after a panicking closure must still run: %+v", rec)
	}
}

// TestServerRouteTelemetryWithoutSinkFallsBackToGoroutine covers a Server
// built directly (no NewServer, no sink): writes still land, one goroutine
// per write as before.
func TestServerRouteTelemetryWithoutSinkFallsBackToGoroutine(t *testing.T) {
	st := store.NewMemory(store.Config{})
	s := &Server{store: st, logger: quietLogger()}

	s.submitRouteRecord(routeRec("ns-1", 1, "p"))
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(st.InferenceRouteRecordsSince(time.Time{})) == 1 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	s.submitRouteOutcome("ns-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success"})
	for time.Now().Before(deadline) {
		recs := st.InferenceRouteRecordsSince(time.Time{})
		if len(recs) == 1 && recs[0].FinalStatus == "success" {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("fallback path did not persist: %+v", st.InferenceRouteRecordsSince(time.Time{}))
}

// TestServerRouteTelemetryThroughSink wires the production path: NewServer's
// sink, the dispatch-side record helper, and the outcome funnel every
// terminal uses (updateInferenceRouteOutcomeWithModel).
func TestServerRouteTelemetryThroughSink(t *testing.T) {
	srv, st := testServer(t)
	if srv.routeTelemetry == nil {
		t.Fatal("NewServer must install the telemetry sink")
	}

	srv.submitRouteRecord(routeRec("ts-1", 1, "p"))
	srv.updateInferenceRouteOutcomeWithModel("ts-1", 1, "m", &store.InferenceRouteOutcome{FinalStatus: "success", CompletionTokens: 4, CompletionTokensSet: true})

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, r := range st.InferenceRouteRecordsSince(time.Time{}) {
			if r.RequestID == "ts-1" && r.FinalStatus == "success" && r.CompletionTokens == 4 {
				return
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("sink path did not persist within the window: %+v", st.InferenceRouteRecordsSince(time.Time{}))
}
