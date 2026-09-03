package api

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// countingVerificationStore counts durable due-row loads.
type countingVerificationStore struct {
	*store.MemoryStore
	loads atomic.Int64
}

func (s *countingVerificationStore) ListDueVerificationJobsPage(
	ctx context.Context, now time.Time, limit, offset int,
) ([]store.VerificationJob, error) {
	s.loads.Add(1)
	return s.MemoryStore.ListDueVerificationJobsPage(ctx, now, limit, offset)
}

type timerRecorder struct {
	mu        sync.Mutex
	durations []time.Duration
}

func (r *timerRecorder) newTimer(d time.Duration) mdmSchedulerTimer {
	r.mu.Lock()
	r.durations = append(r.durations, d)
	r.mu.Unlock()
	return realMDMSchedulerTimer{time.NewTimer(d)}
}

func (r *timerRecorder) reset() {
	r.mu.Lock()
	r.durations = nil
	r.mu.Unlock()
}

func (r *timerRecorder) shortest() (time.Duration, int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	shortest := time.Duration(-1)
	for _, d := range r.durations {
		if shortest < 0 || d < shortest {
			shortest = d
		}
	}
	return shortest, len(r.durations)
}

// TestMDMSchedulerBusyWorkersDoNotReloadDueRowsPerWake: with 100 due rows
// queued and every worker busy, a second of dispatcher wakes re-reads the
// durable table at most twice (the 1 s cadence) and never arms the 1 ms retry
// timer. Before the fix each of the ~200 wakes ran a table scan.
func TestMDMSchedulerBusyWorkersDoNotReloadDueRowsPerWake(t *testing.T) {
	release := make(chan struct{})
	var active atomic.Int32
	execute := func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		active.Add(1)
		defer active.Add(-1)
		select {
		case <-release:
		case <-ctx.Done():
		}
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeTransient}
	}
	timers := &timerRecorder{}
	st := &countingVerificationStore{MemoryStore: store.NewMemory(store.Config{})}
	srv, sch := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 256, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		execute:  execute,
		newTimer: timers.newTimer,
	})
	for i := range 100 {
		p := schedulerTestProvider(t, srv, fmt.Sprintf("busy-%d", i), fmt.Sprintf("se-busy-%d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityFirstOrExpired)
		sch.ChallengeSettled(p, false)
	}
	waitSchedulerCondition(t, func() bool { return active.Load() == 1 }, "the single worker never became busy")
	sch.mu.Lock()
	queued := len(sch.jobs)
	sch.mu.Unlock()
	if queued != 100 {
		t.Fatalf("queued jobs = %d, want 100", queued)
	}

	// Let the pass that dispatched the first job settle, then measure one
	// second of retry wakes while the worker stays busy.
	time.Sleep(50 * time.Millisecond)
	timers.reset()
	loadsBefore := st.loads.Load()
	start := time.Now()
	for time.Since(start) < time.Second {
		sch.signal()
		time.Sleep(5 * time.Millisecond)
	}
	loads := st.loads.Load() - loadsBefore
	if loads > 2 {
		t.Fatalf("durable due-row loads during 1 s of busy retry wakes = %d, want <= 2", loads)
	}
	shortest, armed := timers.shortest()
	if armed == 0 {
		t.Fatal("dispatcher armed no timers during the busy window")
	}
	if shortest < mdmSchedulerBusyRetryDelay {
		t.Fatalf("shortest retry timer while no worker was free = %s, want >= %s", shortest, mdmSchedulerBusyRetryDelay)
	}

	close(release)
	waitSchedulerCondition(t, func() bool { return active.Load() == 0 }, "attempts did not drain")
}

// TestMDMSchedulerEmptyQueueReloadsOnWake: with nothing queued a wake still
// re-reads the durable table, so rows persisted by another instance (or a
// restart) are picked up without waiting for the cadence.
func TestMDMSchedulerEmptyQueueReloadsOnWake(t *testing.T) {
	st := &countingVerificationStore{MemoryStore: store.NewMemory(store.Config{})}
	_, sch := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
	}, mdmSchedulerDeps{})
	sch.Start()
	waitSchedulerCondition(t, func() bool { return st.loads.Load() >= 1 }, "dispatcher never loaded on start")

	before := st.loads.Load()
	sch.signal()
	waitSchedulerCondition(t, func() bool { return st.loads.Load() > before }, "wake with an empty queue did not reload due rows")
}

// TestMDMSchedulerRetryTimerStaysFastWhenWorkerFree: the 250 ms floor applies
// only while no worker is free; with capacity available a due-but-unrunnable
// job keeps the 1 ms retry.
func TestMDMSchedulerRetryTimerStaysFastWhenWorkerFree(t *testing.T) {
	now := time.Date(2026, 9, 3, 12, 0, 0, 0, time.UTC)
	_, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 2, QueueCapacity: 8}, mdmSchedulerDeps{
		now: func() time.Time { return now },
	})
	sch.mu.Lock()
	sch.jobs["due"] = &mdmScheduledJob{record: store.VerificationJob{
		State: store.VerificationStatePending, NextAttemptAt: now.Add(-time.Second),
	}}
	sch.mu.Unlock()
	if got := sch.nextDispatchDelay(); got != time.Millisecond {
		t.Fatalf("delay with a free worker = %s, want 1ms", got)
	}
	sch.mu.Lock()
	sch.active[store.VerificationTaskSecurityInfo] = 2
	sch.mu.Unlock()
	if got := sch.nextDispatchDelay(); got != mdmSchedulerBusyRetryDelay {
		t.Fatalf("delay with every worker busy = %s, want %s", got, mdmSchedulerBusyRetryDelay)
	}
}
