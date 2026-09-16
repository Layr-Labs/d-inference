package outcomequeue

import (
	"context"
	"fmt"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRequestOutcomeQueueCloseDrainsBatches(t *testing.T) {
	st := store.NewMemory(store.Config{})
	var sizes []int
	var mu sync.Mutex
	// Fill the owned buffer before starting its worker so this close/drain
	// oracle does not depend on racing the periodic flush during submission.
	q := &Sink{ch: make(chan store.RequestOutcomeRecord, 300), stop: make(chan struct{}), done: make(chan struct{}), hooks: Hooks{Write: func(ctx context.Context, rows []store.RequestOutcomeRecord) error {
		if deadline, ok := ctx.Deadline(); !ok || time.Until(deadline) > time.Second {
			return fmt.Errorf("missing one-second write deadline")
		}
		if err := st.RecordRequestOutcomes(ctx, rows); err != nil {
			return err
		}
		mu.Lock()
		sizes = append(sizes, len(rows))
		mu.Unlock()
		return nil
	}}}
	t.Cleanup(q.Close)
	now := time.Now()
	for i := 0; i < 260; i++ {
		q.MarkReceived()
		q.Submit(store.RequestOutcomeRecord{CoordRequestID: fmt.Sprintf("request-%d", i), SchemaVersion: store.RequestOutcomeSchemaVersion, Revision: 1, ReceivedAt: now, UpdatedAt: now})
	}
	go q.run()
	q.Close()
	stats := q.Stats()
	if stats.Received != 260 || stats.Written != 260 || stats.Dropped != 0 || stats.Failed != 0 || stats.Queued != 0 {
		t.Fatalf("incomplete drain: %+v", stats)
	}
	mu.Lock()
	gotSizes := append([]int(nil), sizes...)
	mu.Unlock()
	if !reflect.DeepEqual(gotSizes, []int{128, 128, 4}) {
		t.Fatalf("batch sizes = %v, want [128 128 4]", gotSizes)
	}
	rows, err := st.RequestOutcomes(context.Background(), now.Add(-time.Second), now.Add(time.Second), 300)
	if err != nil || len(rows) != 260 {
		t.Fatalf("persisted rows=%d err=%v", len(rows), err)
	}
	q.Submit(store.RequestOutcomeRecord{})
	if got := q.Stats(); got.Written != 260 || got.Dropped != 1 {
		t.Fatalf("post-close snapshot not rejected: %+v", got)
	}
}

func TestRequestOutcomeQueueWriteDeadlineCountsFailure(t *testing.T) {
	q := New(Hooks{Write: func(ctx context.Context, _ []store.RequestOutcomeRecord) error {
		<-ctx.Done()
		return ctx.Err()
	}}, 1)
	t.Cleanup(q.Close)
	q.Submit(store.RequestOutcomeRecord{})
	start := time.Now()
	q.Close()
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("close exceeded deadline with scheduler slack: %s", elapsed)
	}
	if got := q.Stats(); got.Failed != 1 || got.Written != 0 {
		t.Fatalf("timed-out write counts = %+v", got)
	}
}
