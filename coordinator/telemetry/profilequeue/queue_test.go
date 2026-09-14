package profilequeue

import (
	"io"
	"log/slog"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type recordingWriter struct {
	*store.MemoryStore
	mu      sync.Mutex
	batches []int
}

func (w *recordingWriter) RecordRequestProfiles(rows []*store.RequestProfileRecord) error {
	if err := w.MemoryStore.RecordRequestProfiles(rows); err != nil {
		return err
	}
	w.mu.Lock()
	w.batches = append(w.batches, len(rows))
	w.mu.Unlock()
	return nil
}

func (w *recordingWriter) batchSizes() []int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]int(nil), w.batches...)
}

func newWriter() *recordingWriter {
	return &recordingWriter{MemoryStore: store.NewMemory(store.Config{})}
}

func fixtureAttempt(id string) (*registry.RequestProfile, *registry.AttemptProfile) {
	rp := registry.NewRequestProfile(time.Now(), id, nil, 0)
	return rp, rp.NewAttempt(id, 0, "")
}

func fixtureRecord(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
	return &store.RequestProfileRecord{CoordRequestID: rp.CoordRequestID, RequestID: ap.RequestID, ReceivedAt: rp.T0}
}

func waitWritten(t *testing.T, q *Sink, want int64) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for q.WrittenTotal() != want && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := q.WrittenTotal(); got != want {
		t.Fatalf("written = %d, want %d", got, want)
	}
}

func TestProfileQueueBuildDoesNotBlockSubmit(t *testing.T) {
	w := newWriter()
	started, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	unblock := func() { releaseOnce.Do(func() { close(release) }) }
	t.Cleanup(unblock)
	var buildOnce sync.Once
	q := New(Hooks{Store: func() Writer { return w }, Build: func(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
		buildOnce.Do(func() { close(started) })
		<-release
		return fixtureRecord(rp, ap)
	}}, 1)
	t.Cleanup(q.Close)
	rp, ap := fixtureAttempt("first")
	if !q.Submit(rp, ap) {
		t.Fatal("first job was rejected")
	}
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("worker never started building")
	}
	rp, ap = fixtureAttempt("second")
	if !q.Submit(rp, ap) {
		t.Fatal("buffered job was rejected")
	}
	rp, ap = fixtureAttempt("dropped")
	accepted := make(chan bool, 1)
	go func() { accepted <- q.Submit(rp, ap) }()
	select {
	case ok := <-accepted:
		if ok {
			t.Fatal("full queue accepted a third job")
		}
	case <-time.After(time.Second):
		t.Fatal("submission waited for record construction")
	}
	if q.Depth() != 1 || q.DroppedTotal() != 1 {
		t.Fatalf("queue depth=%d dropped=%d", q.Depth(), q.DroppedTotal())
	}
	unblock()
	waitWritten(t, q, 2)
	if got := w.batchSizes(); !reflect.DeepEqual(got, []int{2}) {
		t.Fatalf("quiet queue batches = %v, want [2]", got)
	}
	for _, row := range w.RequestProfilesSince(time.Time{}) {
		if row.RequestID == "dropped" {
			t.Fatal("dropped job reached the store")
		}
	}
}

func TestProfileQueueBuildFailureKeepsLaterRecords(t *testing.T) {
	w := newWriter()
	q := New(Hooks{
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Store:  func() Writer { return w },
		Build: func(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
			switch ap.RequestID {
			case "panic":
				panic("owned build fixture")
			case "sampled-out":
				return nil
			}
			return fixtureRecord(rp, ap)
		},
	}, 4)
	t.Cleanup(q.Close)
	for _, id := range []string{"panic", "sampled-out", "written"} {
		rp, ap := fixtureAttempt(id)
		if !q.Submit(rp, ap) {
			t.Fatalf("job %q was rejected", id)
		}
	}
	waitWritten(t, q, 1)
	rows := w.RequestProfilesSince(time.Time{})
	if len(rows) != 1 || rows[0].RequestID != "written" || q.DroppedTotal() != 0 {
		t.Fatalf("rows=%+v dropped=%d", rows, q.DroppedTotal())
	}
}

func TestProfileQueueBatchLimitAndQuietRemainder(t *testing.T) {
	w := newWriter()
	// Hold the first build until every job is queued. The 250ms quiet timer
	// then starts with a full buffer, independent of fixture scheduling.
	release := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	t.Cleanup(unblock)
	q := New(Hooks{Build: func(rp *registry.RequestProfile, ap *registry.AttemptProfile) *store.RequestProfileRecord {
		<-release
		return fixtureRecord(rp, ap)
	}, Store: func() Writer { return w }}, 65)
	t.Cleanup(q.Close)
	for i := 0; i < 65; i++ {
		rp, ap := fixtureAttempt(time.Unix(int64(i), 0).Format(time.RFC3339))
		if !q.Submit(rp, ap) {
			t.Fatalf("job %d was rejected", i)
		}
	}
	unblock()
	waitWritten(t, q, 65)
	if got := w.batchSizes(); !reflect.DeepEqual(got, []int{64, 1}) {
		t.Fatalf("batches = %v, want [64 1]", got)
	}
	if got := len(w.RequestProfilesSince(time.Time{})); got != 65 {
		t.Fatalf("store has %d records, want 65", got)
	}
}
