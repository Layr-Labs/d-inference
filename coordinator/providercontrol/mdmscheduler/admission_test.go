package mdmscheduler

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDMSchedulerGlobalConcurrencyCap(t *testing.T) {
	var active atomic.Int32
	var maximum atomic.Int32
	release := make(chan struct{})
	execute := func(ctx context.Context, _ Target, _ store.VerificationTaskKind, _ string) AttemptResult {
		current := active.Add(1)
		for {
			old := maximum.Load()
			if current <= old || maximum.CompareAndSwap(old, current) {
				break
			}
		}
		select {
		case <-release:
		case <-ctx.Done():
		}
		active.Add(-1)
		return AttemptResult{Outcome: store.VerificationOutcomeTransient}
	}
	srv, _, sch := newSchedulerHarness(t, Config{Workers: 12, QueueCapacity: 128, InitialSpreadMax: time.Nanosecond}, Dependencies{
		Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: execute,
	})
	for i := range 64 {
		p := schedulerProvider(t, srv, fmt.Sprintf("cap-%d", i), fmt.Sprintf("se-cap-%d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityFirstOrExpired)
		sch.ChallengeSettled(p, false)
	}
	waitSchedulerCondition(t, func() bool { return maximum.Load() == 12 }, "workers did not fill the configured cap")
	if maximum.Load() > 12 {
		t.Fatalf("active attempts reached %d, cap is 12", maximum.Load())
	}
	close(release)
	waitSchedulerCondition(t, func() bool { return active.Load() == 0 }, "attempts did not drain")
}

func TestMDMSchedulerBoundedQueuePrioritizesUnverified(t *testing.T) {
	srv, st, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 3}, Dependencies{})
	for i := range 3 {
		p := schedulerProvider(t, srv, fmt.Sprintf("refresh-%d", i), fmt.Sprintf("se-refresh-%d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	}
	high := schedulerProvider(t, srv, "first", "se-first")
	sch.Submit(context.Background(), high.ID, high, store.VerificationPriorityFirstOrExpired)
	sch.mu.Lock()
	defer sch.mu.Unlock()
	if len(sch.jobs) != 3 {
		t.Fatalf("in-memory queue size = %d, want 3", len(sch.jobs))
	}
	if sch.jobs[jobKey("se-first", store.VerificationTaskSecurityInfo)] == nil {
		t.Fatal("first/expired work did not evict a redundant refresh")
	}
	persisted, err := st.GetVerificationJob(context.Background(), "se-refresh-0", store.VerificationTaskSecurityInfo)
	if err != nil || persisted == nil {
		t.Fatalf("evicted refresh was not retained durably: %+v, %v", persisted, err)
	}
}

// TestMDMSchedulerFirstOrExpiredDueImmediatelyDespiteSpread pins the P1 fix:
// the configured 5s–5m initial spread must never delay first/expired work,
// whose provider has no usable trust grant while a client request burns the
// 120s dispatch-queue deadline. Even with worst-case jitter, a first/expired
// settle becomes due within firstVerifySpreadMax, while a refresh settle
// keeps the full configured spread.
func TestMDMSchedulerFirstOrExpiredDueImmediatelyDespiteSpread(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerHarness(t, Config{
		Workers: 1, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, Dependencies{
		Now: func() time.Time { return now },
		// Worst-case draw: whatever range the scheduler requests, take its top.
		Jitter: func(_, maximum time.Duration) time.Duration { return maximum },
	})

	first := schedulerProvider(t, srv, "urgent", "se-urgent")
	sch.Submit(context.Background(), first.ID, first, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(first, false)
	rec, err := st.GetVerificationJob(context.Background(), "se-urgent", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil {
		t.Fatalf("first/expired job not persisted: %+v, %v", rec, err)
	}
	if due := rec.NextAttemptAt.Sub(now); due > firstVerifySpreadMax {
		t.Fatalf("first/expired due %s after settle, must be within %s", due, firstVerifySpreadMax)
	}

	refresh := schedulerProvider(t, srv, "routine", "se-routine")
	sch.Submit(context.Background(), refresh.ID, refresh, store.VerificationPriorityRefresh)
	sch.ChallengeSettled(refresh, false)
	rec, err = st.GetVerificationJob(context.Background(), "se-routine", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil {
		t.Fatalf("refresh job not persisted: %+v, %v", rec, err)
	}
	if due := rec.NextAttemptAt.Sub(now); due != 20*time.Minute {
		t.Fatalf("refresh due %s after settle, want the full 20m spread", due)
	}
}

// TestMDMSchedulerFirstOrExpiredDispatchesBeforeRefreshSpread proves the fix
// end-to-end on the real dispatch loop: with the production floor of each
// jitter range, a first/expired settle executes immediately while a refresh
// settle stays parked behind its spread floor.
func TestMDMSchedulerFirstOrExpiredDispatchesBeforeRefreshSpread(t *testing.T) {
	executed := make(chan string, 4)
	srv, _, sch := newSchedulerHarness(t, Config{
		Workers: 2, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, Dependencies{
		Jitter: func(minimum, _ time.Duration) time.Duration { return minimum },
		Execute: func(_ context.Context, binding Target, _ store.VerificationTaskKind, _ string) AttemptResult {
			executed <- binding.Attestation.PublicKey
			return AttemptResult{Outcome: store.VerificationOutcomeSuccess, Terminal: true}
		},
	})

	refresh := schedulerProvider(t, srv, "routine", "se-routine")
	sch.Submit(context.Background(), refresh.ID, refresh, store.VerificationPriorityRefresh)
	sch.ChallengeSettled(refresh, false)
	urgent := schedulerProvider(t, srv, "urgent", "se-urgent")
	sch.Submit(context.Background(), urgent.ID, urgent, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(urgent, false)

	select {
	case seKey := <-executed:
		if seKey != "se-urgent" {
			t.Fatalf("dispatched %q first, want the first/expired provider", seKey)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("first/expired verification never dispatched; initial spread deferred it")
	}
	select {
	case seKey := <-executed:
		t.Fatalf("refresh %q dispatched inside its spread floor", seKey)
	case <-time.After(100 * time.Millisecond):
	}
}

// TestFailedFastSkipPromotesRefreshToImmediateDue (Codex P1): a job classified
// refresh at submit (hasFreshRecord looked good) whose fast-skip then DECLINES
// must not settle onto the refresh spread — the provider holds no usable trust
// grant while a routed client request burns the 120s dispatch-queue deadline.
// The production read path calls PromoteFailedFastSkip before the settle, and
// the durable row must come out first/expired and due within
// firstVerifySpreadMax even under worst-case jitter.
func TestFailedFastSkipPromotesRefreshToImmediateDue(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerHarness(t, Config{
		Workers: 1, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, Dependencies{
		Now: func() time.Time { return now },
		// Worst-case draw: whatever range the scheduler requests, take its top.
		Jitter: func(_, maximum time.Duration) time.Duration { return maximum },
	})

	p := schedulerProvider(t, srv, "miss", "se-miss")
	sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	sch.PromoteFailedFastSkip(p)
	sch.ChallengeSettled(p, false)

	rec, err := st.GetVerificationJob(context.Background(), "se-miss", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil {
		t.Fatalf("promoted job not persisted: %+v, %v", rec, err)
	}
	if rec.Priority != store.VerificationPriorityFirstOrExpired {
		t.Fatalf("priority = %q after failed fast-skip, want promoted first/expired", rec.Priority)
	}
	if due := rec.NextAttemptAt.Sub(now); due > firstVerifySpreadMax {
		t.Fatalf("failed fast-skip settle due %s out, must be within %s", due, firstVerifySpreadMax)
	}
}

// TestMDMSchedulerReservedUrgentWorkerSlot proves the urgent reservation:
// long-running refresh MDA attempts may fill every general worker slot but
// never the reserved one, and a first/expired SecurityInfo job dispatches
// immediately through the reserved slot while the MDA attempts stay blocked.
func TestMDMSchedulerReservedUrgentWorkerSlot(t *testing.T) {
	releaseMDA := make(chan struct{})
	var mdaActive atomic.Int32
	urgentExecuted := make(chan struct{}, 1)
	execute := func(ctx context.Context, binding Target, kind store.VerificationTaskKind, _ string) AttemptResult {
		if kind == store.VerificationTaskMDA {
			mdaActive.Add(1)
			select {
			case <-releaseMDA:
			case <-ctx.Done():
			}
			mdaActive.Add(-1)
			return AttemptResult{Outcome: store.VerificationOutcomeSuccess, Granted: true, Terminal: true}
		}
		if binding.Attestation.PublicKey == "se-urgent" {
			urgentExecuted <- struct{}{}
			return AttemptResult{Outcome: store.VerificationOutcomeInvalid, Terminal: true}
		}
		return AttemptResult{
			Outcome: store.VerificationOutcomeSuccess, Granted: true, Terminal: true,
			UDID: "udid-" + binding.Attestation.PublicKey,
		}
	}
	srv, _, sch := newSchedulerHarness(t, Config{
		Workers: 3, QueueCapacity: 16, InitialSpreadMax: time.Nanosecond,
	}, Dependencies{
		Jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		Execute:  execute,
		ReuseMDA: func(Target) bool { return false },
	})

	// Three refresh providers: each SecurityInfo grant enqueues a blocked
	// refresh MDA attempt. General capacity is Workers-1 = 2, so at most two
	// MDA attempts may run; further refresh work must stay queued because it
	// can never occupy the reserved urgent slot.
	for i := range 3 {
		p := schedulerProvider(t, srv, fmt.Sprintf("routine-%d", i), fmt.Sprintf("se-routine-%d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
		sch.ChallengeSettled(p, false)
	}
	waitSchedulerCondition(t, func() bool { return mdaActive.Load() == 2 }, "refresh MDA attempts did not fill the general worker slots")
	time.Sleep(50 * time.Millisecond)
	if got := mdaActive.Load(); got != 2 {
		t.Fatalf("refresh MDA attempts occupied %d workers, general capacity is 2", got)
	}

	urgent := schedulerProvider(t, srv, "urgent", "se-urgent")
	sch.Submit(context.Background(), urgent.ID, urgent, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(urgent, false)
	select {
	case <-urgentExecuted:
	case <-time.After(3 * time.Second):
		t.Fatal("first/expired SecurityInfo never dispatched; refresh work starved the reserved slot")
	}
	if got := mdaActive.Load(); got != 2 {
		t.Fatalf("reserved slot leaked to refresh work while urgent ran: %d MDA attempts active", got)
	}
	close(releaseMDA)
	waitSchedulerCondition(t, func() bool { return mdaActive.Load() == 0 }, "blocked MDA attempts did not drain")
}

func TestMDMSchedulerMDAUsesSharedCapAndLowerPriority(t *testing.T) {
	kindStarted := make(chan store.VerificationTaskKind, 2)
	release := make(chan struct{}, 2)
	execute := func(ctx context.Context, _ Target, kind store.VerificationTaskKind, _ string) AttemptResult {
		kindStarted <- kind
		select {
		case <-release:
		case <-ctx.Done():
		}
		return AttemptResult{Outcome: store.VerificationOutcomeInvalid, Terminal: true}
	}
	srv, _, sch := newSchedulerHarness(t, Config{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, Dependencies{Jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, Execute: execute})
	mdaProvider := schedulerProvider(t, srv, "mda", "se-mda")
	mdaProvider.Mu().Lock()
	mdaProvider.TrustLevel = registry.TrustHardware
	mdaProvider.Mu().Unlock()
	mdaGeneration := sch.generation.Add(1)
	mdaBinding := &Binding{providerID: mdaProvider.ID, provider: mdaProvider, attestation: *mdaProvider.GetAttestationResult(), generation: mdaGeneration, ctx: context.Background(), challengeSettled: true, allowMDA: true}
	sch.mu.Lock()
	sch.bindings["se-mda"] = mdaBinding
	sch.mu.Unlock()
	sch.enqueueMDA(*mdaBinding, "udid-mda")
	security := schedulerProvider(t, srv, "security", "se-security")
	securityGeneration := sch.generation.Add(1)
	now := sch.deps.Now().UTC()
	securityRecord, err := sch.store.UpsertVerificationJob(
		context.Background(),
		store.VerificationJob{
			SEPubKey: "se-security", Serial: "serial-security",
			Kind:          store.VerificationTaskSecurityInfo,
			State:         store.VerificationStatePending,
			Priority:      store.VerificationPriorityFirstOrExpired,
			NextAttemptAt: now, UpdatedAt: now,
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	securityKey := jobKey(
		"se-security", store.VerificationTaskSecurityInfo,
	)
	sch.mu.Lock()
	sch.bindings["se-security"] = &Binding{
		providerID: security.ID, provider: security,
		attestation: *security.GetAttestationResult(),
		generation:  securityGeneration, ctx: context.Background(),
		challengeSettled: true,
	}
	sch.jobs[securityKey] = &scheduledJob{
		record: securityRecord, bindingGen: securityGeneration,
		enqueuedAt: now,
	}
	sch.mu.Unlock()
	sch.Start()
	sch.signal()
	select {
	case kind := <-kindStarted:
		if kind != store.VerificationTaskSecurityInfo {
			t.Fatalf("lower-priority MDA started before SecurityInfo: %s", kind)
		}
	case <-time.After(time.Second):
		t.Fatal("no shared-budget attempt started")
	}
	sch.mu.Lock()
	totalActive := 0
	for _, n := range sch.active {
		totalActive += n
	}
	sch.mu.Unlock()
	if totalActive != 1 {
		t.Fatalf("shared active budget = %d, want 1", totalActive)
	}
	release <- struct{}{}
	select {
	case kind := <-kindStarted:
		if kind != store.VerificationTaskMDA {
			t.Fatalf("second kind = %s", kind)
		}
	case <-time.After(time.Second):
		t.Fatal("MDA follow-on did not run")
	}
	release <- struct{}{}
}
