package api

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func withSchedulerTestExecutor(deps mdmSchedulerDeps) mdmSchedulerDeps {
	if deps.execute == nil {
		deps.execute = func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			return mdmSchedulerAttemptResult{
				outcome:  store.VerificationOutcomeInvalid,
				terminal: true,
			}
		}
	}
	return deps
}

func newSchedulerTestServer(
	t *testing.T,
	cfg MDMSchedulerConfig,
	deps mdmSchedulerDeps,
) (*Server, *store.MemoryStore, *mdmVerificationScheduler) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	sch := newMDMVerificationScheduler(srv, cfg, withSchedulerTestExecutor(deps))
	srv.mdmScheduler = sch
	t.Cleanup(srv.Close)
	return srv, st, sch
}

func newSchedulerTestServerWithStore(
	t *testing.T,
	st store.Store,
	cfg MDMSchedulerConfig,
	deps mdmSchedulerDeps,
) (*Server, *mdmVerificationScheduler) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	sch := newMDMVerificationScheduler(srv, cfg, withSchedulerTestExecutor(deps))
	srv.mdmScheduler = sch
	t.Cleanup(srv.Close)
	return srv, sch
}

type cancelAwareVerificationStore struct {
	*store.MemoryStore
}

func (s *cancelAwareVerificationStore) ReleaseVerificationJob(
	ctx context.Context,
	seKey string,
	kind store.VerificationTaskKind,
	owner string,
	now time.Time,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return s.MemoryStore.ReleaseVerificationJob(ctx, seKey, kind, owner, now)
}

type releaseFailingVerificationStore struct {
	*store.MemoryStore
}

func (s *releaseFailingVerificationStore) ReleaseVerificationJob(
	context.Context,
	string,
	store.VerificationTaskKind,
	string,
	time.Time,
) error {
	return fmt.Errorf("release unavailable")
}

func schedulerTestProvider(t *testing.T, srv *Server, id, seKey string) *registry.Provider {
	t.Helper()
	p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", Version: "1.0.0",
		Hardware:  protocol.Hardware{ChipName: "Apple M4 Max", MemoryGB: 64},
		PublicKey: testPublicKeyB64(),
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustSelfSigned
	p.AttestationResult = &attestation.VerificationResult{
		Valid: true, SerialNumber: "serial-" + id,
		SIPEnabled: true, SecureBootEnabled: true, PublicKey: seKey,
	}
	p.Mu().Unlock()
	return p
}

func waitSchedulerCondition(t *testing.T, condition func() bool, message string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal(message)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestMDMSchedulerGlobalConcurrencyCap(t *testing.T) {
	var active atomic.Int32
	var maximum atomic.Int32
	release := make(chan struct{})
	execute := func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
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
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeTransient}
	}
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 12, QueueCapacity: 128, InitialSpreadMax: time.Nanosecond}, mdmSchedulerDeps{
		jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, execute: execute,
	})
	for i := range 64 {
		p := schedulerTestProvider(t, srv, fmt.Sprintf("cap-%d", i), fmt.Sprintf("se-cap-%d", i))
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
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 3}, mdmSchedulerDeps{})
	for i := range 3 {
		p := schedulerTestProvider(t, srv, fmt.Sprintf("refresh-%d", i), fmt.Sprintf("se-refresh-%d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	}
	high := schedulerTestProvider(t, srv, "first", "se-first")
	sch.Submit(context.Background(), high.ID, high, store.VerificationPriorityFirstOrExpired)
	sch.mu.Lock()
	defer sch.mu.Unlock()
	if len(sch.jobs) != 3 {
		t.Fatalf("in-memory queue size = %d, want 3", len(sch.jobs))
	}
	if sch.jobs[verificationSchedulerKey("se-first", store.VerificationTaskSecurityInfo)] == nil {
		t.Fatal("first/expired work did not evict a redundant refresh")
	}
	persisted, err := st.GetVerificationJob(context.Background(), "se-refresh-0", store.VerificationTaskSecurityInfo)
	if err != nil || persisted == nil {
		t.Fatalf("evicted refresh was not retained durably: %+v, %v", persisted, err)
	}
}

func TestMDMSchedulerSingleflightAcrossReconnectPreservesDue(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var jitterCalls atomic.Int32
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8, InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute}, mdmSchedulerDeps{
		now: func() time.Time { return now },
		jitter: func(time.Duration, time.Duration) time.Duration {
			if jitterCalls.Add(1) == 1 {
				return 7 * time.Minute
			}
			return 19 * time.Minute
		},
	})
	first := schedulerTestProvider(t, srv, "rebind-a", "se-rebind")
	g1 := sch.Submit(context.Background(), first.ID, first, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(first, false)
	rec, _ := sch.store.GetVerificationJob(context.Background(), "se-rebind", store.VerificationTaskSecurityInfo)
	originalDue := rec.NextAttemptAt
	second := schedulerTestProvider(t, srv, "rebind-b", "se-rebind")
	g2 := sch.Submit(context.Background(), second.ID, second, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(second, false)
	rec, _ = sch.store.GetVerificationJob(context.Background(), "se-rebind", store.VerificationTaskSecurityInfo)
	if g2 <= g1 || !rec.NextAttemptAt.Equal(originalDue) {
		t.Fatalf("rebind generation/due = %d/%s, want >%d/%s", g2, rec.NextAttemptAt, g1, originalDue)
	}
	sch.mu.Lock()
	jobs := len(sch.jobs)
	boundProvider := sch.bindings["se-rebind"].provider
	sch.mu.Unlock()
	if jobs != 1 || boundProvider != second {
		t.Fatalf("singleflight jobs=%d current_binding=%v", jobs, boundProvider == second)
	}
}

// TestMDMSchedulerFirstOrExpiredDueImmediatelyDespiteSpread pins the P1 fix:
// the configured 5s–5m initial spread must never delay first/expired work,
// whose provider has no usable trust grant while a client request burns the
// 120s dispatch-queue deadline. Even with worst-case jitter, a first/expired
// settle becomes due within mdmFirstVerifySpreadMax, while a refresh settle
// keeps the full configured spread.
func TestMDMSchedulerFirstOrExpiredDueImmediatelyDespiteSpread(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, mdmSchedulerDeps{
		now: func() time.Time { return now },
		// Worst-case draw: whatever range the scheduler requests, take its top.
		jitter: func(_, maximum time.Duration) time.Duration { return maximum },
	})

	first := schedulerTestProvider(t, srv, "urgent", "se-urgent")
	sch.Submit(context.Background(), first.ID, first, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(first, false)
	rec, err := st.GetVerificationJob(context.Background(), "se-urgent", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil {
		t.Fatalf("first/expired job not persisted: %+v, %v", rec, err)
	}
	if due := rec.NextAttemptAt.Sub(now); due > mdmFirstVerifySpreadMax {
		t.Fatalf("first/expired due %s after settle, must be within %s", due, mdmFirstVerifySpreadMax)
	}

	refresh := schedulerTestProvider(t, srv, "routine", "se-routine")
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
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 2, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, mdmSchedulerDeps{
		jitter: func(minimum, _ time.Duration) time.Duration { return minimum },
		execute: func(_ context.Context, binding mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			executed <- binding.attestation.PublicKey
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeSuccess, terminal: true}
		},
	})

	refresh := schedulerTestProvider(t, srv, "routine", "se-routine")
	sch.Submit(context.Background(), refresh.ID, refresh, store.VerificationPriorityRefresh)
	sch.ChallengeSettled(refresh, false)
	urgent := schedulerTestProvider(t, srv, "urgent", "se-urgent")
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
// mdmFirstVerifySpreadMax even under worst-case jitter.
func TestFailedFastSkipPromotesRefreshToImmediateDue(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, mdmSchedulerDeps{
		now: func() time.Time { return now },
		// Worst-case draw: whatever range the scheduler requests, take its top.
		jitter: func(_, maximum time.Duration) time.Duration { return maximum },
	})

	p := schedulerTestProvider(t, srv, "miss", "se-miss")
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
	if due := rec.NextAttemptAt.Sub(now); due > mdmFirstVerifySpreadMax {
		t.Fatalf("failed fast-skip settle due %s out, must be within %s", due, mdmFirstVerifySpreadMax)
	}
}

// TestContinuityMissPromotesRefreshSubmitToImmediateDue: the continuity path
// widens what counts as a reuse candidate, so the submit-time classification
// can be refresh purely on a continuity-covered record. If the gap outgrows
// the reconnect allowance between submit and challenge, the fast-skip declines
// and the promotion must still land the live verification on immediate
// first/expired scheduling — mirroring the production sequence
// (verificationSubmitPriority → Submit → failed fast-skip →
// PromoteFailedFastSkip → ChallengeSettled).
func TestContinuityMissPromotesRefreshSubmitToImmediateDue(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, mdmSchedulerDeps{
		now:    func() time.Time { return now },
		jitter: func(_, maximum time.Duration) time.Duration { return maximum },
	})
	srv.mdmClient = dummyMDMClient()
	cur := now
	srv.trustReuseCache.now = func() time.Time { return cur }

	p := schedulerTestProvider(t, srv, "cont-miss", "se-cont-miss")
	// Stale window, continuity-covered 60s ago → a reuse candidate at submit.
	srv.trustReuseCache.recordTrust(coveredReuseRecord(
		"se-cont-miss", "serial-cont-miss", trHashA,
		cur.Add(-20*time.Minute), cur.Add(-60*time.Second)))
	priority := srv.verificationSubmitPriority("se-cont-miss", "serial-cont-miss")
	if priority != store.VerificationPriorityRefresh {
		t.Fatalf("submit priority = %q, want refresh for a continuity candidate", priority)
	}
	sch.Submit(context.Background(), p.ID, p, priority)

	// The measured gap outgrows the allowance before the challenge settles.
	cur = cur.Add(2 * time.Minute)
	resp := &protocol.AttestationResponseMessage{
		BinaryHash: trHashA,
		SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
	}
	if srv.tryTrustReuseFastSkip(p.ID, p, resp, true) {
		t.Fatal("outgrown continuity gap must decline the fast-skip")
	}
	sch.PromoteFailedFastSkip(p)
	sch.ChallengeSettled(p, false)

	rec, err := st.GetVerificationJob(context.Background(), "se-cont-miss", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil {
		t.Fatalf("promoted job not persisted: %+v, %v", rec, err)
	}
	if rec.Priority != store.VerificationPriorityFirstOrExpired {
		t.Fatalf("priority = %q after continuity miss, want promoted first/expired", rec.Priority)
	}
	if due := rec.NextAttemptAt.Sub(now); due > mdmFirstVerifySpreadMax {
		t.Fatalf("continuity-miss settle due %s out, must be within %s", due, mdmFirstVerifySpreadMax)
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
	execute := func(ctx context.Context, binding mdmLiveBinding, kind store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		if kind == store.VerificationTaskMDA {
			mdaActive.Add(1)
			select {
			case <-releaseMDA:
			case <-ctx.Done():
			}
			mdaActive.Add(-1)
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeSuccess, granted: true, terminal: true}
		}
		if binding.attestation.PublicKey == "se-urgent" {
			urgentExecuted <- struct{}{}
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeInvalid, terminal: true}
		}
		return mdmSchedulerAttemptResult{
			outcome: store.VerificationOutcomeSuccess, granted: true, terminal: true,
			udid: "udid-" + binding.attestation.PublicKey,
		}
	}
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 3, QueueCapacity: 16, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		execute:  execute,
		reuseMDA: func(mdmLiveBinding) bool { return false },
	})

	// Three refresh providers: each SecurityInfo grant enqueues a blocked
	// refresh MDA attempt. General capacity is Workers-1 = 2, so at most two
	// MDA attempts may run; further refresh work must stay queued because it
	// can never occupy the reserved urgent slot.
	for i := range 3 {
		p := schedulerTestProvider(t, srv, fmt.Sprintf("routine-%d", i), fmt.Sprintf("se-routine-%d", i))
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
		sch.ChallengeSettled(p, false)
	}
	waitSchedulerCondition(t, func() bool { return mdaActive.Load() == 2 }, "refresh MDA attempts did not fill the general worker slots")
	time.Sleep(50 * time.Millisecond)
	if got := mdaActive.Load(); got != 2 {
		t.Fatalf("refresh MDA attempts occupied %d workers, general capacity is 2", got)
	}

	urgent := schedulerTestProvider(t, srv, "urgent", "se-urgent")
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

func TestMDMSchedulerObserveAttemptUDIDDoesNotDeadlock(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
	}, mdmSchedulerDeps{now: func() time.Time { return now }})
	provider := schedulerTestProvider(t, srv, "observe", "se-observe")
	pending, err := st.UpsertVerificationJob(context.Background(), store.VerificationJob{
		SEPubKey: "se-observe", Serial: "serial-observe",
		Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending,
		Priority: store.VerificationPriorityRecovery, NextAttemptAt: now, UpdatedAt: now,
	})
	if err != nil {
		t.Fatal(err)
	}
	claimed, ok, err := st.ClaimVerificationJob(
		context.Background(), pending.SEPubKey, pending.Kind,
		sch.owner, now, now.Add(time.Minute),
	)
	if err != nil || !ok {
		t.Fatalf("claim observe job: ok=%v err=%v", ok, err)
	}
	generation := sch.generation.Add(1)
	key := verificationSchedulerKey(claimed.SEPubKey, claimed.Kind)
	sch.mu.Lock()
	sch.bindings[claimed.SEPubKey] = &mdmLiveBinding{
		providerID: provider.ID, provider: provider,
		attestation: *provider.GetAttestationResult(),
		generation:  generation, ctx: context.Background(), challengeSettled: true,
	}
	sch.jobs[key] = &mdmScheduledJob{
		record: claimed, bindingGen: generation, running: true,
	}
	sch.mu.Unlock()

	done := make(chan struct{})
	go func() {
		sch.ObserveAttemptUDID(provider, "udid-observe")
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("ObserveAttemptUDID deadlocked while persisting the observed UDID")
	}
	sch.mu.Lock()
	job := sch.jobs[key]
	udidOnly := job != nil && job.record.UDID == "udid-observe" &&
		job.callbackGen == 0 && job.callbackUUID == "" &&
		sch.byUDID["udid-observe"] == ""
	sch.mu.Unlock()
	if !udidOnly {
		t.Fatal("UDID observation created callback authority before command binding")
	}
	sch.ObserveAttemptCommand(
		provider, store.VerificationTaskSecurityInfo,
		"udid-observe", "command-observe",
	)
	sch.mu.Lock()
	exact := job.callbackGen == generation &&
		job.callbackUUID == "command-observe" &&
		sch.byUDID["udid-observe"] == key
	sch.mu.Unlock()
	if !exact {
		t.Fatal("command observation did not bind exact late-callback ownership")
	}
}

func TestMDMSchedulerCrossInstanceOldCompletionReopensCurrentBinding(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	st := store.NewMemory(store.Config{})
	oldStarted := make(chan struct{}, 1)
	finishOld := make(chan struct{})
	srvOld, oldScheduler := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		now: func() time.Time { return now },
		jitter: func(time.Duration, time.Duration) time.Duration {
			return 0
		},
		reuseMDA: func(mdmLiveBinding) bool { return true },
		execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			oldStarted <- struct{}{}
			select {
			case <-finishOld:
				return mdmSchedulerAttemptResult{
					outcome: store.VerificationOutcomeSuccess,
					granted: true,
				}
			case <-ctx.Done():
				return mdmSchedulerAttemptResult{
					outcome: store.VerificationOutcomeCancelled,
				}
			}
		},
	})
	oldProvider := schedulerTestProvider(t, srvOld, "cross-old", "se-cross")
	oldScheduler.Submit(context.Background(), oldProvider.ID, oldProvider, store.VerificationPriorityRecovery)
	oldScheduler.ChallengeSettled(oldProvider, false)
	select {
	case <-oldStarted:
	case <-time.After(time.Second):
		t.Fatal("old coordinator did not claim work")
	}

	currentStarted := make(chan struct{}, 1)
	srvCurrent, currentScheduler := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		now: func() time.Time { return now },
		jitter: func(time.Duration, time.Duration) time.Duration {
			return 0
		},
		execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			currentStarted <- struct{}{}
			return mdmSchedulerAttemptResult{
				outcome: store.VerificationOutcomeInvalid, terminal: true,
			}
		},
	})
	currentProvider := schedulerTestProvider(t, srvCurrent, "cross-current", "se-cross")
	currentScheduler.Submit(
		context.Background(), currentProvider.ID, currentProvider,
		store.VerificationPriorityRecovery,
	)
	currentScheduler.ChallengeSettled(currentProvider, false)
	marked, err := st.GetVerificationJob(
		context.Background(), "se-cross", store.VerificationTaskSecurityInfo,
	)
	if err != nil || marked == nil || marked.State != store.VerificationStateRunning ||
		!marked.ReopenPending {
		t.Fatalf("replacement challenge did not mark running row for reopen: %+v, err=%v", marked, err)
	}

	close(finishOld)
	if currentProvider.GetTrustLevel() != registry.TrustSelfSigned {
		t.Fatal("current binding inherited old coordinator live trust")
	}
	select {
	case <-currentStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("current binding was not dispatched after old completion reopened the durable row")
	}
	waitSchedulerCondition(t, func() bool {
		rec, getErr := st.GetVerificationJob(
			context.Background(), "se-cross", store.VerificationTaskSecurityInfo,
		)
		return getErr == nil && rec != nil &&
			rec.State == store.VerificationStateCompleted &&
			rec.LastOutcome == store.VerificationOutcomeInvalid
	}, "current-generation result did not complete its reopened row")
}

func TestMDMSchedulerOldCompletionBeforeReplacementChallengeReopensCurrentBinding(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	st := store.NewMemory(store.Config{})
	oldStarted := make(chan struct{}, 1)
	finishOld := make(chan struct{})
	srvOld, oldScheduler := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		now:      func() time.Time { return now },
		jitter:   func(time.Duration, time.Duration) time.Duration { return 0 },
		reuseMDA: func(mdmLiveBinding) bool { return true },
		execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			oldStarted <- struct{}{}
			select {
			case <-finishOld:
				return mdmSchedulerAttemptResult{
					outcome: store.VerificationOutcomeSuccess,
					granted: true,
				}
			case <-ctx.Done():
				return mdmSchedulerAttemptResult{
					outcome: store.VerificationOutcomeCancelled,
				}
			}
		},
	})
	oldProvider := schedulerTestProvider(
		t, srvOld, "cross-before-challenge-old",
		"se-cross-before-challenge",
	)
	oldScheduler.Submit(
		context.Background(), oldProvider.ID, oldProvider,
		store.VerificationPriorityRecovery,
	)
	oldScheduler.ChallengeSettled(oldProvider, false)
	select {
	case <-oldStarted:
	case <-time.After(time.Second):
		t.Fatal("old coordinator did not claim work")
	}

	currentStarted := make(chan struct{}, 1)
	srvCurrent, currentScheduler := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		now:    func() time.Time { return now },
		jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			currentStarted <- struct{}{}
			return mdmSchedulerAttemptResult{
				outcome:  store.VerificationOutcomeInvalid,
				terminal: true,
			}
		},
	})
	currentProvider := schedulerTestProvider(
		t, srvCurrent, "cross-before-challenge-current",
		"se-cross-before-challenge",
	)
	currentScheduler.Submit(
		context.Background(), currentProvider.ID, currentProvider,
		store.VerificationPriorityRecovery,
	)
	close(finishOld)
	waitSchedulerCondition(t, func() bool {
		rec, err := st.GetVerificationJob(
			context.Background(), "se-cross-before-challenge",
			store.VerificationTaskSecurityInfo,
		)
		return err == nil && rec != nil &&
			rec.State == store.VerificationStateCompleted
	}, "old coordinator did not complete before replacement challenge")

	currentScheduler.ChallengeSettled(currentProvider, false)
	select {
	case <-currentStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("replacement challenge did not reopen completed old work")
	}
	if currentProvider.GetTrustLevel() != registry.TrustSelfSigned {
		t.Fatal("replacement inherited old coordinator live trust")
	}
}

func TestMDMSchedulerReconnectDuringInflightRefreshesReleasedClaim(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	started := make(chan struct{}, 1)
	finishOld := make(chan struct{})
	execute := func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		started <- struct{}{}
		select {
		case <-finishOld:
			return mdmSchedulerAttemptResult{
				outcome: store.VerificationOutcomeTransient,
			}
		case <-ctx.Done():
			return mdmSchedulerAttemptResult{
				outcome: store.VerificationOutcomeCancelled,
			}
		}
	}
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, mdmSchedulerDeps{
		now: func() time.Time { return now },
		jitter: func(minimum, _ time.Duration) time.Duration {
			if minimum >= mdmRetryFirstMin {
				return minimum
			}
			return 0
		},
		execute: execute,
	})
	old := schedulerTestProvider(t, srv, "old-generation", "se-inflight")
	sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(old, false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("old attempt did not start")
	}
	newProvider := schedulerTestProvider(t, srv, "new-generation", "se-inflight")
	newGeneration := sch.Submit(context.Background(), newProvider.ID, newProvider, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(newProvider, false)
	close(finishOld)
	waitSchedulerCondition(t, func() bool {
		rec, err := st.GetVerificationJob(
			context.Background(), "se-inflight", store.VerificationTaskSecurityInfo,
		)
		return err == nil && rec != nil &&
			rec.State == store.VerificationStateBackoff &&
			rec.RetryStage == 1 && rec.ClaimOwner == ""
	}, "rebound job was not refreshed and redispatched from its persisted due time")
	sch.mu.Lock()
	job := sch.jobs[verificationSchedulerKey("se-inflight", store.VerificationTaskSecurityInfo)]
	inMemoryCurrent := job != nil && job.bindingGen == newGeneration &&
		job.record.State == store.VerificationStateBackoff &&
		job.record.RetryStage == 1 && job.record.ClaimOwner == ""
	sch.mu.Unlock()
	if !inMemoryCurrent {
		t.Fatal("rebound in-memory job did not adopt authoritative backoff state")
	}
	rec, err := st.GetVerificationJob(context.Background(), "se-inflight", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State != store.VerificationStateBackoff ||
		rec.RetryStage != 1 || !rec.NextAttemptAt.Equal(now.Add(mdmRetryFirstMin)) {
		t.Fatalf("authoritative rebound state = %+v, err=%v", rec, err)
	}
}

func TestMDMSchedulerDisconnectCancelsQueuedAndRunning(t *testing.T) {
	started := make(chan struct{}, 1)
	cancelled := make(chan struct{}, 1)
	execute := func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		started <- struct{}{}
		<-ctx.Done()
		cancelled <- struct{}{}
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeCancelled}
	}
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, mdmSchedulerDeps{
		jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, execute: execute,
	})
	p := schedulerTestProvider(t, srv, "disconnect", "se-disconnect")
	g := sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(p, false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("attempt did not start")
	}
	sch.Unbind("se-disconnect", g)
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		t.Fatal("running attempt was not cancelled")
	}
	waitSchedulerCondition(t, func() bool { sch.mu.Lock(); defer sch.mu.Unlock(); return len(sch.jobs) == 0 }, "disconnected job remained in memory")
	rec, err := st.GetVerificationJob(context.Background(), "se-disconnect", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State == store.VerificationStateCompleted {
		t.Fatalf("disconnect discarded durable retry state: %+v, %v", rec, err)
	}
}

func TestMDMSchedulerWorkerPersistsResultsBeforeCancellingAttempt(t *testing.T) {
	tests := []struct {
		name    string
		result  mdmSchedulerAttemptResult
		state   store.VerificationTaskState
		outcome store.VerificationOutcome
		stage   int
	}{
		{
			name: "success",
			result: mdmSchedulerAttemptResult{
				outcome: store.VerificationOutcomeSuccess, granted: true,
			},
			state: store.VerificationStateCompleted, outcome: store.VerificationOutcomeSuccess,
		},
		{
			name: "transient",
			result: mdmSchedulerAttemptResult{
				outcome: store.VerificationOutcomeTransient,
			},
			state: store.VerificationStateBackoff, outcome: store.VerificationOutcomeTransient,
			stage: 1,
		},
		{
			name: "terminal",
			result: mdmSchedulerAttemptResult{
				outcome: store.VerificationOutcomeInvalid, terminal: true,
			},
			state: store.VerificationStateCompleted, outcome: store.VerificationOutcomeInvalid,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
				Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
			}, mdmSchedulerDeps{
				jitter: func(minimum, _ time.Duration) time.Duration {
					if minimum >= mdmRetryFirstMin {
						return minimum
					}
					return 0
				},
				reuseMDA: func(mdmLiveBinding) bool { return true },
				execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
					return tc.result
				},
			})
			seKey := "se-result-" + tc.name
			provider := schedulerTestProvider(t, srv, "result-"+tc.name, seKey)
			sch.Submit(
				context.Background(), provider.ID, provider,
				store.VerificationPriorityRecovery,
			)
			sch.ChallengeSettled(provider, false)
			waitSchedulerCondition(t, func() bool {
				rec, err := st.GetVerificationJob(
					context.Background(), seKey, store.VerificationTaskSecurityInfo,
				)
				return err == nil && rec != nil &&
					rec.State == tc.state && rec.LastOutcome == tc.outcome &&
					rec.RetryStage == tc.stage && rec.ClaimOwner == ""
			}, "worker result was released instead of persisted")
		})
	}
}

func TestMDMSchedulerReleaseErrorDropsDisconnectedOrphan(t *testing.T) {
	st := &releaseFailingVerificationStore{MemoryStore: store.NewMemory(store.Config{})}
	started := make(chan struct{}, 1)
	srv, sch := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			started <- struct{}{}
			<-ctx.Done()
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeCancelled}
		},
	})
	provider := schedulerTestProvider(t, srv, "release-error", "se-release-error")
	generation := sch.Submit(
		context.Background(), provider.ID, provider,
		store.VerificationPriorityRecovery,
	)
	sch.ChallengeSettled(provider, false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("release-error attempt did not start")
	}
	sch.Unbind("se-release-error", generation)
	waitSchedulerCondition(t, func() bool {
		sch.mu.Lock()
		defer sch.mu.Unlock()
		return sch.jobs[verificationSchedulerKey(
			"se-release-error", store.VerificationTaskSecurityInfo,
		)] == nil
	}, "failed claim release left a disconnected orphan consuming queue memory")
	rec, err := st.GetVerificationJob(
		context.Background(), "se-release-error", store.VerificationTaskSecurityInfo,
	)
	if err != nil || rec == nil || rec.State != store.VerificationStateRunning {
		t.Fatalf("release failure unexpectedly discarded durable recovery state: %+v, err=%v", rec, err)
	}
}
func TestMDMSchedulerFastSkipCancelsBeforeCommand(t *testing.T) {
	var attempts atomic.Int32
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8}, mdmSchedulerDeps{
		execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			attempts.Add(1)
			return mdmSchedulerAttemptResult{}
		},
	})
	p := schedulerTestProvider(t, srv, "fast", "se-fast")
	sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
	sch.ChallengeSettled(p, true)
	time.Sleep(10 * time.Millisecond)
	if attempts.Load() != 0 {
		t.Fatalf("fast skip sent %d commands", attempts.Load())
	}
	rec, err := st.GetVerificationJob(context.Background(), "se-fast", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil || rec.State != store.VerificationStateCompleted || rec.LastOutcome != store.VerificationOutcomeReused {
		t.Fatalf("fast skip durable state = %+v, %v", rec, err)
	}
}

func TestMDMSchedulerRetryWindowsPersistAndDoNotSynchronize(t *testing.T) {
	var sequence atomic.Int64
	_, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{}, mdmSchedulerDeps{
		jitter: func(minimum, maximum time.Duration) time.Duration {
			n := time.Duration(sequence.Add(1))
			return minimum + n%(maximum-minimum)
		},
	})
	seen := map[time.Duration]bool{}
	for stage, bounds := range map[int][2]time.Duration{
		1: {mdmRetryFirstMin, mdmRetryFirstMax}, 2: {mdmRetrySecondMin, mdmRetrySecondMax}, 3: {mdmRetrySteadyMin, mdmRetrySteadyMax},
	} {
		for range 20 {
			delay := sch.retryDelay(stage)
			if delay < bounds[0] || delay > bounds[1] {
				t.Fatalf("stage %d delay %s outside %s..%s", stage, delay, bounds[0], bounds[1])
			}
			seen[delay] = true
		}
	}
	if len(seen) < 10 {
		t.Fatalf("retry jitter synchronized: only %d distinct due offsets", len(seen))
	}
}

func TestMDMSchedulerQueueFullRemainsDurableAndRestartReseeds(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 1}, mdmSchedulerDeps{now: func() time.Time { return now }})
	first := schedulerTestProvider(t, srv, "queue-one", "se-queue-one")
	second := schedulerTestProvider(t, srv, "queue-two", "se-queue-two")
	sch.Submit(context.Background(), first.ID, first, store.VerificationPriorityRefresh)
	sch.Submit(context.Background(), second.ID, second, store.VerificationPriorityRefresh)
	sch.mu.Lock()
	inMemory := len(sch.jobs)
	sch.mu.Unlock()
	if inMemory != 1 {
		t.Fatalf("bounded queue contains %d jobs", inMemory)
	}
	persisted, err := st.GetVerificationJob(context.Background(), "se-queue-two", store.VerificationTaskSecurityInfo)
	if err != nil || persisted == nil {
		t.Fatalf("queue-full job not durable: %+v, %v", persisted, err)
	}

	due := now.Add(11 * time.Minute)
	_, err = st.UpsertVerificationJob(context.Background(), store.VerificationJob{SEPubKey: "se-reseed", Serial: "serial", Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStateBackoff, Priority: store.VerificationPriorityRecovery, RetryStage: 2, PreviousDelay: 11 * time.Minute, NextAttemptAt: due, LastOutcome: store.VerificationOutcomeTimeout, UpdatedAt: now})
	if err != nil {
		t.Fatal(err)
	}
	reseed := schedulerTestProvider(t, srv, "reseed", "se-reseed")
	sch.Submit(context.Background(), reseed.ID, reseed, store.VerificationPriorityFirstOrExpired)
	sch.ChallengeSettled(reseed, false)
	rec, _ := st.GetVerificationJob(context.Background(), "se-reseed", store.VerificationTaskSecurityInfo)
	if rec.RetryStage != 2 || !rec.NextAttemptAt.Equal(due) {
		t.Fatalf("restart/reconnect reset backoff: %+v", rec)
	}
}

func TestMDMSchedulerQueueRejectedChallengeSettlesDurablyAndReseeds(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var clock atomic.Int64
	clock.Store(now.UnixNano())
	nowFn := func() time.Time { return time.Unix(0, clock.Load()).UTC() }
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 1,
		InitialSpreadMin: 3 * time.Minute, InitialSpreadMax: 3 * time.Minute,
	}, mdmSchedulerDeps{now: nowFn, jitter: func(time.Duration, time.Duration) time.Duration {
		return 3 * time.Minute
	}})
	evicted := schedulerTestProvider(t, srv, "evicted-refresh", "se-evicted-refresh")
	sch.Submit(context.Background(), evicted.ID, evicted, store.VerificationPriorityRefresh)
	urgent := schedulerTestProvider(t, srv, "urgent-first", "se-urgent-first")
	urgentGeneration := sch.Submit(
		context.Background(), urgent.ID, urgent,
		store.VerificationPriorityFirstOrExpired,
	)

	sch.ChallengeSettled(evicted, false)
	durable, err := st.GetVerificationJob(
		context.Background(), "se-evicted-refresh",
		store.VerificationTaskSecurityInfo,
	)
	wantDue := now.Add(3 * time.Minute)
	if err != nil || durable == nil ||
		durable.State != store.VerificationStatePending ||
		!durable.NextAttemptAt.Equal(wantDue) {
		t.Fatalf("evicted challenge settlement = %+v, err=%v", durable, err)
	}
	sch.Unbind("se-urgent-first", urgentGeneration)
	clock.Store(wantDue.UnixNano())
	sch.loadDueRows()
	sch.mu.Lock()
	reseeded := sch.jobs[verificationSchedulerKey(
		"se-evicted-refresh", store.VerificationTaskSecurityInfo,
	)]
	var reseededRecord store.VerificationJob
	if reseeded != nil {
		reseededRecord = reseeded.record // copied under the lock: the live dispatcher may claim it
	}
	sch.mu.Unlock()
	if reseeded == nil || !reseededRecord.NextAttemptAt.Equal(wantDue) {
		t.Fatalf("durable queue-pressure job was not reseeded at preserved due time: %+v", reseededRecord)
	}
}

func TestMDMSchedulerDuePagingCannotStarveLiveRowBehindDisconnectedPrefix(t *testing.T) {
	base := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	due := base.Add(time.Hour)
	var clock atomic.Int64
	clock.Store(base.UnixNano())
	nowFn := func() time.Time { return time.Unix(0, clock.Load()).UTC() }
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 2,
		InitialSpreadMin: time.Hour, InitialSpreadMax: time.Hour,
	}, mdmSchedulerDeps{
		now: nowFn,
		jitter: func(time.Duration, time.Duration) time.Duration {
			return time.Hour
		},
	})
	for i := range 5 {
		_, err := st.UpsertVerificationJob(context.Background(), store.VerificationJob{
			SEPubKey:      fmt.Sprintf("a-disconnected-%02d", i),
			Serial:        fmt.Sprintf("serial-disconnected-%02d", i),
			Kind:          store.VerificationTaskSecurityInfo,
			State:         store.VerificationStatePending,
			Priority:      store.VerificationPriorityFirstOrExpired,
			NextAttemptAt: due,
			UpdatedAt:     base,
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	first := schedulerTestProvider(t, srv, "paging-filler-1", "se-paging-filler-1")
	second := schedulerTestProvider(t, srv, "paging-filler-2", "se-paging-filler-2")
	firstGeneration := sch.Submit(
		context.Background(), first.ID, first, store.VerificationPriorityRefresh,
	)
	secondGeneration := sch.Submit(
		context.Background(), second.ID, second, store.VerificationPriorityRefresh,
	)
	live := schedulerTestProvider(t, srv, "paging-live", "z-se-paging-live")
	sch.Submit(
		context.Background(), live.ID, live, store.VerificationPriorityRefresh,
	)
	sch.ChallengeSettled(live, false)
	sch.Unbind("se-paging-filler-1", firstGeneration)
	sch.Unbind("se-paging-filler-2", secondGeneration)

	clock.Store(due.UnixNano())
	for range 4 {
		sch.loadDueRows()
	}
	sch.mu.Lock()
	reseeded := sch.jobs[verificationSchedulerKey(
		"z-se-paging-live", store.VerificationTaskSecurityInfo,
	)]
	var reseededDue time.Time
	if reseeded != nil {
		reseededDue = reseeded.record.NextAttemptAt // read under the lock: the live dispatcher may claim it
	}
	sch.mu.Unlock()
	if reseeded == nil {
		t.Fatal("live queue-rejected row remained hidden behind disconnected due-row prefix")
	}
	if !reseededDue.Equal(due) {
		t.Fatalf("paged reseed due = %s, want %s", reseededDue, due)
	}
}

func TestMDMSchedulerRestartBeforeClaimExpiryReclaimsAfterExpiry(t *testing.T) {
	base := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var clock atomic.Int64
	clock.Store(base.UnixNano())
	nowFn := func() time.Time { return time.Unix(0, clock.Load()).UTC() }
	st := store.NewMemory(store.Config{})
	_, err := st.UpsertVerificationJob(context.Background(), store.VerificationJob{
		SEPubKey: "se-expired-claim", Serial: "serial-expired-claim",
		Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending,
		Priority: store.VerificationPriorityRecovery, NextAttemptAt: base, UpdatedAt: base,
	})
	if err != nil {
		t.Fatal(err)
	}
	expiry := base.Add(time.Minute)
	if _, ok, claimErr := st.ClaimVerificationJob(
		context.Background(), "se-expired-claim",
		store.VerificationTaskSecurityInfo, "dead-coordinator", base, expiry,
	); claimErr != nil || !ok {
		t.Fatalf("seed expired claim: ok=%v err=%v", ok, claimErr)
	}
	attempted := make(chan struct{}, 1)
	srv, sch := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, ClaimTTL: 5 * time.Minute,
		InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		now:    nowFn,
		jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			attempted <- struct{}{}
			return mdmSchedulerAttemptResult{
				outcome: store.VerificationOutcomeSuccess, terminal: true,
			}
		},
	})
	provider := schedulerTestProvider(t, srv, "expired-claim", "se-expired-claim")
	sch.Submit(context.Background(), provider.ID, provider, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(provider, false)
	select {
	case <-attempted:
		t.Fatal("replacement coordinator stole a live claim")
	case <-time.After(20 * time.Millisecond):
	}
	clock.Store(expiry.Add(time.Nanosecond).UnixNano())
	sch.signal()
	select {
	case <-attempted:
	case <-time.After(time.Second):
		t.Fatal("expired running placeholder was not reloaded and reclaimed")
	}
}

func TestMDMSchedulerCloseReleasesClaimWithLiveCleanupContext(t *testing.T) {
	st := &cancelAwareVerificationStore{MemoryStore: store.NewMemory(store.Config{})}
	started := make(chan struct{}, 1)
	srv1, sch1 := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, ClaimTTL: 10 * time.Minute,
		InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			started <- struct{}{}
			<-ctx.Done()
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeCancelled}
		},
	})
	first := schedulerTestProvider(t, srv1, "close-first", "se-close-release")
	sch1.Submit(context.Background(), first.ID, first, store.VerificationPriorityRecovery)
	sch1.ChallengeSettled(first, false)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("first coordinator did not claim work")
	}
	sch1.Close()
	released, err := st.GetVerificationJob(
		context.Background(), "se-close-release",
		store.VerificationTaskSecurityInfo,
	)
	if err != nil || released == nil ||
		released.State != store.VerificationStatePending ||
		released.ClaimOwner != "" {
		t.Fatalf("shutdown claim release = %+v, err=%v", released, err)
	}

	replacementStarted := make(chan struct{}, 1)
	srv2, sch2 := newSchedulerTestServerWithStore(t, st, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8, ClaimTTL: 10 * time.Minute,
		InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		jitter: func(time.Duration, time.Duration) time.Duration { return 0 },
		execute: func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			replacementStarted <- struct{}{}
			return mdmSchedulerAttemptResult{
				outcome: store.VerificationOutcomeSuccess, terminal: true,
			}
		},
	})
	replacement := schedulerTestProvider(t, srv2, "close-replacement", "se-close-release")
	sch2.Submit(context.Background(), replacement.ID, replacement, store.VerificationPriorityRecovery)
	sch2.ChallengeSettled(replacement, false)
	select {
	case <-replacementStarted:
	case <-time.After(time.Second):
		t.Fatal("replacement coordinator could not promptly reclaim released work")
	}
}

func TestMDMSchedulerHardBoundsClampEnvironmentAndProgrammaticConfig(t *testing.T) {
	t.Setenv("EIGENINFERENCE_MDM_SCHEDULER_WORKERS", "99")
	t.Setenv("EIGENINFERENCE_MDM_SCHEDULER_QUEUE_CAPACITY", "99999")
	fromEnv := readMDMSchedulerConfig()
	if fromEnv.Workers != defaultMDMVerificationWorkers ||
		fromEnv.QueueCapacity != defaultMDMVerificationQueue {
		t.Fatalf("environment scheduler bounds = %+v", fromEnv)
	}
	clamped := normalizeMDMSchedulerConfig(MDMSchedulerConfig{
		Workers: 99, QueueCapacity: 99999,
	})
	if clamped.Workers != defaultMDMVerificationWorkers ||
		clamped.QueueCapacity != defaultMDMVerificationQueue {
		t.Fatalf("programmatic scheduler bounds = %+v", clamped)
	}
	_, _, constructed := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 99, QueueCapacity: 99999,
	}, mdmSchedulerDeps{})
	if constructed.cfg.Workers != defaultMDMVerificationWorkers ||
		constructed.cfg.QueueCapacity != defaultMDMVerificationQueue {
		t.Fatalf("constructed scheduler bounds = %+v", constructed.cfg)
	}
	lower := normalizeMDMSchedulerConfig(MDMSchedulerConfig{
		Workers: 3, QueueCapacity: 17,
	})
	if lower.Workers != 3 || lower.QueueCapacity != 17 {
		t.Fatalf("lower positive scheduler options were not preserved: %+v", lower)
	}
}

func TestMDMSchedulerGenerationChurnRetainsNoSEKeys(t *testing.T) {
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 1,
	}, mdmSchedulerDeps{})
	const churn = 2000
	for i := range churn {
		seKey := fmt.Sprintf("se-churn-%d", i)
		provider := schedulerTestProvider(t, srv, fmt.Sprintf("churn-%d", i), seKey)
		generation := sch.Submit(
			context.Background(), provider.ID, provider,
			store.VerificationPriorityRefresh,
		)
		sch.Unbind(seKey, generation)
	}
	sch.mu.Lock()
	jobs := len(sch.jobs)
	bindings := len(sch.bindings)
	udids := len(sch.byUDID)
	sch.mu.Unlock()
	if jobs != 0 || bindings != 0 || udids != 0 {
		t.Fatalf("scheduler retained per-SE churn state: jobs=%d bindings=%d udids=%d", jobs, bindings, udids)
	}
	if generation := sch.generation.Load(); generation != churn {
		t.Fatalf("global generation = %d, want %d", generation, churn)
	}
}

func TestMDMSchedulerHardUntrustAndLateSecurityInfoUseCurrentExactBinding(t *testing.T) {
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8}, mdmSchedulerDeps{})
	old := schedulerTestProvider(t, srv, "late-old", "se-late")
	g1 := sch.Submit(context.Background(), old.ID, old, store.VerificationPriorityRecovery)
	sch.ChallengeSettled(old, false)
	sch.mu.Lock()
	key := verificationSchedulerKey("se-late", store.VerificationTaskSecurityInfo)
	sch.jobs[key].record.UDID = "udid-exact"
	sch.jobs[key].callbackGen = g1
	sch.jobs[key].callbackUUID = "old-command"
	sch.byUDID["udid-exact"] = key
	sch.mu.Unlock()

	newProvider := schedulerTestProvider(t, srv, "late-new", "se-late")
	g2 := sch.Submit(context.Background(), newProvider.ID, newProvider, store.VerificationPriorityRecovery)
	if g2 <= g1 {
		t.Fatal("generation did not advance")
	}
	if sch.ApplyLateSecurityInfo(
		"udid-exact", "old-command", true,
	) != nil {
		t.Fatal("old-connection SecurityInfo bound before the new challenge settled")
	}
	sch.ChallengeSettled(newProvider, false)
	if sch.ApplyLateSecurityInfo(
		"udid-exact", "old-command", true,
	) != nil {
		t.Fatal("old-connection SecurityInfo survived the reconnect generation")
	}
	sch.mu.Lock()
	sch.jobs[key].running = true
	sch.mu.Unlock()
	sch.ObserveAttemptUDID(newProvider, "udid-exact")
	sch.ObserveAttemptCommand(
		newProvider, store.VerificationTaskSecurityInfo,
		"udid-exact", "new-command",
	)
	if sch.ApplyLateSecurityInfo(
		"udid-exact", "old-command", true,
	) != nil {
		t.Fatal("old command UUID bound to the current scheduler generation")
	}
	binding := sch.ApplyLateSecurityInfo(
		"udid-exact", "new-command", true,
	)
	if binding == nil || binding.provider != newProvider {
		t.Fatal("late SecurityInfo did not resolve the new generation's exact command")
	}
	if sch.ApplyLateSecurityInfo(
		"udid-other", "new-command", true,
	) != nil {
		t.Fatal("late SecurityInfo attached to a different UDID/provider")
	}
	srv.registry.MarkUntrusted(newProvider.ID)
	if newProvider.GrantHardwareIfNotUntrusted() {
		t.Fatal("late grant resurrected hard-untrusted provider")
	}
}

func TestMDMSchedulerMDAUsesSharedCapAndLowerPriority(t *testing.T) {
	kindStarted := make(chan store.VerificationTaskKind, 2)
	release := make(chan struct{}, 2)
	execute := func(ctx context.Context, _ mdmLiveBinding, kind store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		kindStarted <- kind
		select {
		case <-release:
		case <-ctx.Done():
		}
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeInvalid, terminal: true}
	}
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8, InitialSpreadMax: time.Nanosecond}, mdmSchedulerDeps{jitter: func(time.Duration, time.Duration) time.Duration { return 0 }, execute: execute})
	mdaProvider := schedulerTestProvider(t, srv, "mda", "se-mda")
	mdaProvider.Mu().Lock()
	mdaProvider.TrustLevel = registry.TrustHardware
	mdaProvider.Mu().Unlock()
	mdaGeneration := sch.generation.Add(1)
	mdaBinding := &mdmLiveBinding{providerID: mdaProvider.ID, provider: mdaProvider, attestation: *mdaProvider.GetAttestationResult(), generation: mdaGeneration, ctx: context.Background(), challengeSettled: true, allowMDA: true}
	sch.mu.Lock()
	sch.bindings["se-mda"] = mdaBinding
	sch.mu.Unlock()
	sch.enqueueMDA(*mdaBinding, "udid-mda")
	security := schedulerTestProvider(t, srv, "security", "se-security")
	securityGeneration := sch.generation.Add(1)
	now := sch.deps.now().UTC()
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
	securityKey := verificationSchedulerKey(
		"se-security", store.VerificationTaskSecurityInfo,
	)
	sch.mu.Lock()
	sch.bindings["se-security"] = &mdmLiveBinding{
		providerID: security.ID, provider: security,
		attestation: *security.GetAttestationResult(),
		generation:  securityGeneration, ctx: context.Background(),
		challengeSettled: true,
	}
	sch.jobs[securityKey] = &mdmScheduledJob{
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

func TestMDMSchedulerLateMDACompletesExactUDIDAndSEJob(t *testing.T) {
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 1, QueueCapacity: 8}, mdmSchedulerDeps{})
	exact := schedulerTestProvider(t, srv, "late-mda-exact", "se-late-mda")
	other := schedulerTestProvider(t, srv, "late-mda-other", "se-other-mda")
	exact.Mu().Lock()
	exact.TrustLevel = registry.TrustHardware
	exact.Mu().Unlock()
	other.Mu().Lock()
	other.TrustLevel = registry.TrustHardware
	other.Mu().Unlock()
	mdaGeneration := sch.generation.Add(1)
	binding := mdmLiveBinding{
		providerID: exact.ID, provider: exact,
		attestation: *exact.GetAttestationResult(),
		generation:  mdaGeneration, ctx: context.Background(),
		challengeSettled: false, allowMDA: true,
	}
	sch.mu.Lock()
	sch.bindings["se-late-mda"] = &binding
	sch.mu.Unlock()
	sch.enqueueMDA(binding, "udid-late-mda")
	mdaKey := verificationSchedulerKey("se-late-mda", store.VerificationTaskMDA)
	sch.mu.Lock()
	sch.jobs[mdaKey].callbackGen = mdaGeneration
	sch.jobs[mdaKey].callbackUUID = "mda-command"
	sch.byUDID["udid-late-mda"] = mdaKey
	sch.mu.Unlock()
	freshness := sha256.Sum256([]byte("se-late-mda"))
	chain, root := mintMDALeafChain(t, "serial-late-mda-exact", freshness[:])
	restore := attestation.OverrideRootCAForTest(root)
	defer restore()
	if sch.applyLateMDA("different-udid", "mda-command", chain) {
		t.Fatal("late MDA attached without exact scheduler UDID ownership")
	}
	if !sch.applyLateMDA("udid-late-mda", "mda-command", chain) {
		t.Fatal("exact but unchallenged late MDA callback was not consumed and dropped")
	}
	exact.Mu().Lock()
	verifiedBeforeChallenge := exact.MDAVerified
	exact.Mu().Unlock()
	if verifiedBeforeChallenge {
		t.Fatal("late MDA granted before the current challenge settled")
	}
	sch.mu.Lock()
	sch.bindings["se-late-mda"].challengeSettled = true
	sch.mu.Unlock()
	if !sch.applyLateMDA("udid-late-mda", "mda-command", chain) {
		t.Fatal("exact challenged scheduled late MDA was not consumed")
	}
	exact.Mu().Lock()
	exactVerified := exact.MDAVerified
	exact.Mu().Unlock()
	other.Mu().Lock()
	otherVerified := other.MDAVerified
	other.Mu().Unlock()
	if !exactVerified || otherVerified {
		t.Fatalf("late MDA attachment exact=%v other=%v", exactVerified, otherVerified)
	}
	rec, err := st.GetVerificationJob(context.Background(), "se-late-mda", store.VerificationTaskMDA)
	if err != nil || rec == nil || rec.State != store.VerificationStateCompleted {
		t.Fatalf("late MDA durable completion = %+v, %v", rec, err)
	}
}

func TestMDMSchedulerOldMDAResponseCannotBindReplacementConnection(t *testing.T) {
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
	}, mdmSchedulerDeps{})
	old := schedulerTestProvider(t, srv, "old-mda-connection", "se-mda-reconnect")
	old.Mu().Lock()
	old.TrustLevel = registry.TrustHardware
	old.Mu().Unlock()
	oldGeneration := sch.generation.Add(1)
	binding := mdmLiveBinding{
		providerID: old.ID, provider: old,
		attestation: *old.GetAttestationResult(),
		generation:  oldGeneration, ctx: context.Background(),
		challengeSettled: true, allowMDA: true,
	}
	sch.mu.Lock()
	sch.bindings["se-mda-reconnect"] = &binding
	sch.mu.Unlock()
	sch.enqueueMDA(binding, "udid-mda-reconnect")
	mdaKey := verificationSchedulerKey("se-mda-reconnect", store.VerificationTaskMDA)
	sch.mu.Lock()
	sch.jobs[mdaKey].callbackGen = oldGeneration
	sch.jobs[mdaKey].callbackUUID = "old-mda-command"
	sch.byUDID["udid-mda-reconnect"] = mdaKey
	sch.mu.Unlock()

	replacement := schedulerTestProvider(
		t, srv, "new-mda-connection", "se-mda-reconnect",
	)
	sch.Submit(
		context.Background(), replacement.ID, replacement,
		store.VerificationPriorityRecovery,
	)
	if sch.applyLateMDA(
		"udid-mda-reconnect", "old-mda-command", [][]byte{{1}},
	) {
		t.Fatal("old MDA callback retained ownership after replacement connected")
	}
	old.Mu().Lock()
	oldVerified := old.MDAVerified
	old.Mu().Unlock()
	replacement.Mu().Lock()
	replacementVerified := replacement.MDAVerified
	replacement.Mu().Unlock()
	if oldVerified || replacementVerified {
		t.Fatalf("old MDA callback mutated proof state: old=%v replacement=%v", oldVerified, replacementVerified)
	}
}

func TestMDMSchedulerMetricsUseFixedLowCardinalityEnums(t *testing.T) {
	srv, _, sch := newSchedulerTestServer(t, MDMSchedulerConfig{}, mdmSchedulerDeps{})
	sch.metricCounter("mdm_scheduler_enqueued_total", "reason", "registration")
	sch.metricCounter("mdm_scheduler_deduplicated_total", "state", string(store.VerificationStateBackoff))
	sch.metricCounter("mdm_scheduler_cancelled_total", "reason", "disconnect")
	sch.metricCounter("mdm_scheduler_queue_rejected_total", "priority", "refresh")
	sch.metricCounter("mdm_scheduler_grants_total", "path", "reuse")
	sch.metricCounter("mda_verification_total", "outcome", "binding_mismatch")
	work := mdmSchedulerWork{job: store.VerificationJob{
		SEPubKey: "secret-se-key", Kind: store.VerificationTaskSecurityInfo,
		Priority: store.VerificationPriorityRecovery, UpdatedAt: time.Now(),
	}}
	sch.observeAttempt(work, mdmSchedulerAttemptResult{
		outcome: store.VerificationOutcomeTimeout,
	}, time.Second)
	rendered := srv.metrics.Snapshot().RenderProm()
	for _, name := range []string{
		"mdm_scheduler_queue_depth", "mdm_scheduler_active_attempts",
		"mdm_scheduler_enqueued_total", "mdm_scheduler_deduplicated_total",
		"mdm_scheduler_cancelled_total", "mdm_scheduler_queue_rejected_total",
		"mdm_scheduler_queue_wait_seconds", "mdm_scheduler_attempt_seconds",
		"mdm_scheduler_attempts_total", "mdm_scheduler_timeouts_total",
		"mdm_scheduler_grants_total", "mda_verification_total",
	} {
		if !strings.Contains(rendered, name) {
			t.Fatalf("metric %q missing from snapshot", name)
		}
	}
	if strings.Contains(rendered, "secret-se-key") {
		t.Fatal("scheduler metric labels leaked stable device identity")
	}
}
func TestMDMSchedulerFleet1500LifecycleSimulation(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var clock atomic.Int64
	clock.Store(now.UnixNano())
	nowFn := func() time.Time {
		return time.Unix(0, clock.Load()).UTC()
	}
	var jitterIndex atomic.Int64
	var mdmAttempts atomic.Int32
	var activeAttempts atomic.Int32
	var maximumActive atomic.Int32
	var blockDueWork atomic.Bool
	releaseDueWork := make(chan struct{})
	jitter := func(minimum, maximum time.Duration) time.Duration {
		span := maximum - minimum
		if span <= 0 {
			return minimum
		}
		return minimum + time.Duration(jitterIndex.Add(7919)%int64(span))
	}
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{Workers: 12, QueueCapacity: 4096, InitialSpreadMin: time.Hour, InitialSpreadMax: 2 * time.Hour}, mdmSchedulerDeps{
		now: nowFn, jitter: jitter,
		execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			current := activeAttempts.Add(1)
			for {
				observed := maximumActive.Load()
				if current <= observed || maximumActive.CompareAndSwap(observed, current) {
					break
				}
			}
			mdmAttempts.Add(1)
			if blockDueWork.Load() {
				select {
				case <-releaseDueWork:
				case <-ctx.Done():
					activeAttempts.Add(-1)
					return mdmSchedulerAttemptResult{
						outcome: store.VerificationOutcomeCancelled,
					}
				}
			}
			activeAttempts.Add(-1)
			return mdmSchedulerAttemptResult{
				outcome: store.VerificationOutcomeTransient,
			}
		},
	})
	providers := make([]*registry.Provider, 1500)
	originalDue := make(map[string]time.Time, 1500)
	for i := range providers {
		se := fmt.Sprintf("fleet-se-%04d", i)
		p := schedulerTestProvider(t, srv, fmt.Sprintf("fleet-%04d", i), se)
		providers[i] = p
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityFirstOrExpired)
		sch.ChallengeSettled(p, false)
		rec, err := st.GetVerificationJob(context.Background(), se, store.VerificationTaskSecurityInfo)
		if err != nil || rec == nil {
			t.Fatalf("device %d scheduler state: %+v %v", i, rec, err)
		}
		originalDue[se] = rec.NextAttemptAt
	}
	sch.mu.Lock()
	queueSize := len(sch.jobs)
	active := 0
	for _, n := range sch.active {
		active += n
	}
	sch.mu.Unlock()
	if queueSize != 1500 || queueSize > 4096 {
		t.Fatalf("fleet queue size = %d", queueSize)
	}
	if active > 12 || mdmAttempts.Load() != 0 {
		t.Fatalf("premature/cap attempts active=%d total=%d", active, mdmAttempts.Load())
	}
	dueSet := map[time.Time]struct{}{}
	for _, due := range originalDue {
		dueSet[due] = struct{}{}
	}
	if len(dueSet) < 1000 {
		t.Fatalf("fleet due times synchronized into only %d instants", len(dueSet))
	}

	// Coordinator restart and unchanged second reconnect preserve every durable
	// due time; a live reuse decision completes without executing MDM.
	sch.Close()
	restarted := newMDMVerificationScheduler(srv, sch.cfg, sch.deps)
	srv.mdmScheduler = restarted
	for i, p := range providers {
		generation := restarted.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
		if generation == 0 {
			t.Fatalf("restart bind %d failed", i)
		}
		restarted.ChallengeSettled(p, false)
		se := fmt.Sprintf("fleet-se-%04d", i)
		rec, _ := st.GetVerificationJob(context.Background(), se, store.VerificationTaskSecurityInfo)
		if !rec.NextAttemptAt.Equal(originalDue[se]) {
			t.Fatalf("restart reset due time for %s", se)
		}
	}
	transitionCache := newTrustReuseCacheWithWindow(time.Hour)
	transitionCache.now = func() time.Time { return now }
	for i := range providers {
		se := fmt.Sprintf("fleet-se-%04d", i)
		serial := fmt.Sprintf("serial-fleet-%04d", i)
		transitionCache.recordTrust(hardwareReuseRecord(se, serial, trHashA, now))
		decision := transitionCache.decideTrustReuse(trustReuseInput{
			SEPubKey: se, Serial: serial, FreshBinaryHash: trHashB,
			ReleaseTransition: approvedReleaseTransitionFact{
				Approved: true, BinaryHash: trHashB,
				ApprovedFromBinaryHashes: map[string]struct{}{trHashA: {}},
			},
		})
		if decision.Decision != trustReuseDecisionApprovedReleaseTransition {
			t.Fatalf("approved release transition %d required live MDM: %q", i, decision.Decision)
		}
	}
	for i := range 500 {
		restarted.ChallengeSettled(providers[i], true)
	}
	if mdmAttempts.Load() != 0 {
		t.Fatalf("valid reuse sent %d MDM attempts", mdmAttempts.Load())
	}

	// Advance through one real due-work wave after fast-skipping the approved
	// cohort. This exercises durable claims, the fixed worker pool, result
	// settlement, and retry persistence for the remaining 1,000 providers.
	blockDueWork.Store(true)
	clock.Store(now.Add(3 * time.Hour).UnixNano())
	restarted.signal()
	waitSchedulerCondition(t, func() bool {
		return maximumActive.Load() == 12
	}, "due wave did not fill the fixed worker pool")
	restarted.mu.Lock()
	queueSize = len(restarted.jobs)
	active = 0
	for _, n := range restarted.active {
		active += n
	}
	restarted.mu.Unlock()
	if queueSize > 4096 || active > 12 || maximumActive.Load() > 12 {
		t.Fatalf(
			"due-wave bounds queue=%d active=%d maximum=%d",
			queueSize, active, maximumActive.Load(),
		)
	}
	close(releaseDueWork)
	waitSchedulerCondition(t, func() bool {
		return mdmAttempts.Load() == 1000 && activeAttempts.Load() == 0
	}, "due wave did not execute and settle every non-reused provider")
	attemptsAfterDueWave := mdmAttempts.Load()
	waitSchedulerCondition(t, func() bool {
		for i := 500; i < len(providers); i++ {
			se := fmt.Sprintf("fleet-se-%04d", i)
			rec, err := st.GetVerificationJob(
				context.Background(), se,
				store.VerificationTaskSecurityInfo,
			)
			if err != nil || rec == nil ||
				rec.State != store.VerificationStateBackoff ||
				rec.RetryStage != 1 ||
				rec.LastOutcome != store.VerificationOutcomeTransient ||
				rec.ClaimOwner != "" {
				return false
			}
		}
		return true
	}, "due wave executors returned before durable retry settlement completed")

	// Exact application proof binding: approved same-process reuse spends no APNs;
	// a changed process key cannot reuse the proof and an absent release policy
	// cannot grant an unapproved binary.
	th := newCodeAttestThrottle()
	th.now = func() time.Time { return now }
	th.recordAttestedForProcess("fleet-se-app", "1.0", "token", "process-a", trHashA)
	if !th.reuseAttestation("fleet-se-app", "1.0", "token", "process-a") {
		t.Fatal("valid exact process proof was not reusable")
	}
	if th.reuseAttestation("fleet-se-app", "1.0", "token", "process-b") {
		t.Fatal("changed process key reused APNs proof")
	}
	unapproved := schedulerTestProvider(t, srv, "unapproved", "fleet-se-unapproved")
	unapproved.Mu().Lock()
	unapproved.APNsDeviceToken = "token"
	unapproved.PublicKey = "process-b"
	unapproved.Mu().Unlock()
	if srv.tryCrossVersionReuse(context.Background(), unapproved.ID, unapproved) || unapproved.GetCodeAttested() {
		t.Fatal("unapproved binary gained application trust")
	}

	// Hardware recovery moves through durable recovery/backoff rather than an
	// immediate reconnect reset. A hard-untrust tombstone remains after the same
	// store is reused by another coordinator generation.
	recoverySE := "fleet-se-0500"
	rec, _ := st.GetVerificationJob(context.Background(), recoverySE, store.VerificationTaskSecurityInfo)
	if rec.State == store.VerificationStateCompleted {
		t.Fatal("recovery device unexpectedly completed")
	}
	_, err := st.RevokeProviderTrustReuse(context.Background(), "fleet-se-1499", "fleet-hard-untrust")
	if err != nil {
		t.Fatal(err)
	}
	rows, err := st.ListProviderTrustReuse(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	foundRevoked := false
	for _, row := range rows {
		if row.SEPubKey == "fleet-se-1499" && row.RevokedAt != nil {
			foundRevoked = true
		}
	}
	if !foundRevoked {
		t.Fatal("hard untrust did not survive coordinator restart store")
	}

	// Second reconnect wave remains singleflight and bounded.
	for i := 500; i < len(providers); i++ {
		restarted.Submit(context.Background(), providers[i].ID, providers[i], store.VerificationPriorityRecovery)
		restarted.ChallengeSettled(providers[i], false)
	}
	restarted.mu.Lock()
	queueSize = len(restarted.jobs)
	active = 0
	for _, n := range restarted.active {
		active += n
	}
	restarted.mu.Unlock()
	if queueSize > 4096 || active > 12 ||
		mdmAttempts.Load() != attemptsAfterDueWave {
		t.Fatalf(
			"second reconnect bounds queue=%d active=%d attempts=%d want=%d",
			queueSize, active, mdmAttempts.Load(), attemptsAfterDueWave,
		)
	}
	restarted.Close()
}
