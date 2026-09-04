package api

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// countingDueRowStore forwards to the real memory store and counts due-row
// page scans. It defines ListDueVerificationJobsPage itself so store.As finds
// the paged capability on the wrapper (the embedded Store interface does not
// carry it) and delegates to the inner store's implementation.
type countingDueRowStore struct {
	store.Store
	scans atomic.Int64
}

func (c *countingDueRowStore) ListDueVerificationJobsPage(ctx context.Context, now time.Time, limit, offset int) ([]store.VerificationJob, error) {
	c.scans.Add(1)
	paged, ok := store.As[verificationDuePageStore](c.Store)
	if !ok {
		return c.Store.ListDueVerificationJobs(ctx, now, limit)
	}
	return paged.ListDueVerificationJobsPage(ctx, now, limit, offset)
}

// immediateTimer is already fired when selected on, so the dispatcher loop
// iterates as fast as it can — the shape of its 1 ms retry path under load.
type immediateTimer struct{ c chan time.Time }

func newImmediateTimer() immediateTimer {
	c := make(chan time.Time, 1)
	c <- time.Now()
	return immediateTimer{c: c}
}

func (t immediateTimer) C() <-chan time.Time { return t.c }
func (t immediateTimer) Stop() bool          { return true }

// Measurement (no-work condition): 99 due rows that cannot dispatch because
// the only worker is busy keep the dispatcher on its 1 ms retry path. Before
// this change every iteration re-scanned the durable due-row table; now rows
// load on the 1 s cadence only, so a 300 ms spin performs at most one scan no
// matter how many iterations it runs.
func TestMDMSchedulerLoadsDueRowsOnTickOnly(t *testing.T) {
	mem := store.NewMemory(store.Config{})
	st := &countingDueRowStore{Store: mem}
	var iterations atomic.Int64
	release := make(chan struct{})
	srv, sch := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 256, InitialSpreadMin: 0, InitialSpreadMax: time.Millisecond,
	}, mdmSchedulerDeps{
		newTimer: func(time.Duration) mdmSchedulerTimer {
			iterations.Add(1)
			return newImmediateTimer()
		},
		jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			select {
			case <-release:
			case <-ctx.Done():
			}
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeInvalid, terminal: true}
		},
	})
	// Runs before the server's own cleanup, so the blocked worker is released
	// before the scheduler waits for it.
	t.Cleanup(func() { close(release) })

	for i := 0; i < 100; i++ {
		p := schedulerTestProvider(t, srv, fmt.Sprintf("poll-%03d", i), fmt.Sprintf("se-poll-%03d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityFirstOrExpired)
		sch.ChallengeSettled(p, false)
	}
	waitSchedulerCondition(t, func() bool {
		sch.mu.Lock()
		defer sch.mu.Unlock()
		return sch.active[store.VerificationTaskSecurityInfo] == 1
	}, "the single worker never became busy")

	scansBefore := st.scans.Load()
	itersBefore := iterations.Load()
	time.Sleep(300 * time.Millisecond)
	scans := st.scans.Load() - scansBefore
	iters := iterations.Load() - itersBefore
	t.Logf("loaded machine: %d dispatcher iterations, %d due-row scans in 300 ms (99 due rows, 0 free workers) = %.0f scans/s",
		iters, scans, float64(scans)/0.3)
	if iters < 20 {
		t.Fatalf("dispatcher iterated only %d times; the retry path was not exercised", iters)
	}
	if scans > 1 {
		t.Fatalf("due-row scans during a 300 ms retry spin = %d, want at most 1 (rows load on the 1 s cadence only)", scans)
	}
}
