package registry

import (
	"context"
	"io"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// reputationUpsertCounter counts reputation upserts on top of the real
// in-memory store.
type reputationUpsertCounter struct {
	*store.MemoryStore
	upserts atomic.Int64
}

func (c *reputationUpsertCounter) UpsertReputation(ctx context.Context, providerID string, rep store.ReputationRecord) error {
	err := c.MemoryStore.UpsertReputation(ctx, providerID, rep)
	// Waiters inspect the persisted row after observing this count, so publish
	// completion only after the wrapped write has made that row visible.
	c.upserts.Add(1)
	return err
}

func waitForUpserts(t *testing.T, st *reputationUpsertCounter, want int64) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for st.upserts.Load() < want {
		if time.Now().After(deadline) {
			t.Fatalf("reputation upserts = %d, want >= %d", st.upserts.Load(), want)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// TestRecordJobSuccessPersistsReputationThrottled: 50 completions in one
// second write the reputation row at most twice (the 30 s throttle window),
// the in-memory counters still see all 50, and Disconnect flushes the final
// counts to the store.
func TestRecordJobSuccessPersistsReputationThrottled(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &reputationUpsertCounter{MemoryStore: store.NewMemory(store.Config{})}
	reg := New(logger)
	reg.SetStore(st)

	const id = "throttle-provider"
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{ID: id, Backend: "mlx-swift"}); err != nil {
		t.Fatal(err)
	}
	p := reg.Register(id, nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", Version: "1.0.0",
		Hardware: protocol.Hardware{ChipName: "Apple M4 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "model"}},
	})
	baseline := st.upserts.Load()

	start := time.Now()
	for i := 0; i < 50; i++ {
		reg.RecordJobSuccess(id, 40*time.Millisecond)
		time.Sleep(time.Second / 60)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("50 completions took %s; the throttle assertion assumes about a second", elapsed)
	}
	waitForUpserts(t, st, baseline+1)
	time.Sleep(50 * time.Millisecond)
	if got := st.upserts.Load() - baseline; got > 2 {
		t.Fatalf("reputation upserts for 50 completions in ~1 s = %d, want <= 2", got)
	}
	p.Mu().Lock()
	successes := p.Reputation.SuccessfulJobs
	p.Mu().Unlock()
	if successes != 50 {
		t.Fatalf("in-memory successful jobs = %d, want 50", successes)
	}

	// Disconnect flushes the accumulated counts.
	before := st.upserts.Load()
	reg.Disconnect(id)
	waitForUpserts(t, st, before+1)
	rep, err := st.GetReputation(context.Background(), id)
	if err != nil {
		t.Fatalf("persisted reputation: %v", err)
	}
	if rep.SuccessfulJobs != 50 || rep.TotalJobs != 50 {
		t.Fatalf("persisted reputation after disconnect = %+v, want 50 successful of 50", rep)
	}
}
