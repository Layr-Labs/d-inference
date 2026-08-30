package api

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type blockingCodeAttestStore struct {
	*store.MemoryStore
	blockSE string
	started chan struct{}
	release chan struct{}
	once    sync.Once
	mu      sync.Mutex
	calls   map[string]int
}

func (s *blockingCodeAttestStore) ReserveCodeAttestPushBudget(
	ctx context.Context,
	seKey, tokenHash string,
	now, nextPushAt time.Time,
) (bool, error) {
	s.mu.Lock()
	s.calls[seKey]++
	s.mu.Unlock()
	if seKey == s.blockSE {
		s.once.Do(func() { close(s.started) })
		select {
		case <-ctx.Done():
			return false, ctx.Err()
		case <-s.release:
		}
	}
	return s.MemoryStore.ReserveCodeAttestPushBudget(
		ctx, seKey, tokenHash, now, nextPushAt,
	)
}

func (s *blockingCodeAttestStore) callCount(seKey string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls[seKey]
}

func TestCodeAttestPushAdmissionAtomicAcrossLoopGenerations(t *testing.T) {
	st := store.NewMemory(store.Config{})
	th := newCodeAttestThrottle()
	th.store = st
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return now }
	oldGeneration := th.beginLoop("se-one")
	newGeneration := th.beginLoop("se-one")
	if th.tryReservePush(context.Background(), "se-one", "token", false, oldGeneration) {
		t.Fatal("superseded registration loop spent APNs budget")
	}

	var admitted atomic.Int32
	var wg sync.WaitGroup
	for range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if th.tryReservePush(context.Background(), "se-one", "token", false, newGeneration) {
				admitted.Add(1)
			}
		}()
	}
	wg.Wait()
	if admitted.Load() != 1 {
		t.Fatalf("concurrent registration/rearm admissions = %d, want 1", admitted.Load())
	}
}

func TestCodeAttestTokenRotationSerializesBudgetResetWithReservation(t *testing.T) {
	st := &blockingCodeAttestStore{
		MemoryStore: store.NewMemory(store.Config{}),
		blockSE:     "se-rotate",
		started:     make(chan struct{}),
		release:     make(chan struct{}),
		calls:       make(map[string]int),
	}
	th := newCodeAttestThrottle()
	th.store = st
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return now }
	oldGeneration := th.beginLoop("se-rotate")
	oldResult := make(chan bool, 1)
	go func() {
		oldResult <- th.tryReservePush(
			context.Background(), "se-rotate", "old-token", false,
			oldGeneration,
		)
	}()
	<-st.started

	rotated := make(chan uint64, 1)
	go func() {
		rotated <- th.rotateLoopAndClearPushBudget("se-rotate")
	}()
	select {
	case <-rotated:
		t.Fatal("token rotation bypassed the in-flight per-device reservation")
	case <-time.After(20 * time.Millisecond):
	}
	close(st.release)
	if !<-oldResult {
		t.Fatal("old reservation did not complete before rotation")
	}
	newGeneration := <-rotated
	if th.loopCurrent("se-rotate", oldGeneration) ||
		!th.loopCurrent("se-rotate", newGeneration) {
		t.Fatal("token rotation did not atomically transfer loop ownership")
	}
	if !th.tryReservePush(
		context.Background(), "se-rotate", "new-token", false,
		newGeneration,
	) {
		t.Fatal("new-token loop could not use the atomically cleared budget")
	}
}

func TestCodeAttestZeroCooldownStillMakesValidDurableReservation(t *testing.T) {
	st := store.NewMemory(store.Config{})
	th := newCodeAttestThrottle()
	th.store = st
	th.backgroundPushCooldown = 0
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return now }
	generation := th.beginLoop("se-zero-cooldown")
	if !th.tryReservePush(
		context.Background(), "se-zero-cooldown", "token", false, generation,
	) {
		t.Fatal("zero cooldown produced an invalid durable reservation window")
	}
	rows, err := st.ListCodeAttestPushBudgets(context.Background())
	if err != nil || len(rows) != 1 || !rows[0].NextPushAt.After(now) {
		t.Fatalf("zero-cooldown durable reservation = %+v, err=%v", rows, err)
	}
}

func TestCodeAttestSlowReservationDoesNotBlockOtherDevices(t *testing.T) {
	st := &blockingCodeAttestStore{
		MemoryStore: store.NewMemory(store.Config{}),
		blockSE:     "se-slow", started: make(chan struct{}), release: make(chan struct{}),
		calls: make(map[string]int),
	}
	th := newCodeAttestThrottle()
	th.store = st
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return now }
	slowGeneration := th.beginLoop("se-slow")
	fastGeneration := th.beginLoop("se-fast")
	slowResult := make(chan bool, 1)
	go func() {
		slowResult <- th.tryReservePush(
			context.Background(), "se-slow", "slow-token", false, slowGeneration,
		)
	}()
	<-st.started

	fastResult := make(chan bool, 1)
	go func() {
		fastResult <- th.tryReservePush(
			context.Background(), "se-fast", "fast-token", false, fastGeneration,
		)
	}()
	select {
	case admitted := <-fastResult:
		if !admitted {
			t.Fatal("unblocked device reservation was denied")
		}
	case <-time.After(time.Second):
		t.Fatal("slow durable reservation held the fleet-global throttle mutex")
	}
	close(st.release)
	if !<-slowResult {
		t.Fatal("slow device reservation was denied after release")
	}
}

func TestCodeAttestSameDeviceConcurrentReservationAdmitsOnce(t *testing.T) {
	st := &blockingCodeAttestStore{
		MemoryStore: store.NewMemory(store.Config{}),
		blockSE:     "se-one", started: make(chan struct{}), release: make(chan struct{}),
		calls: make(map[string]int),
	}
	th := newCodeAttestThrottle()
	th.store = st
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return now }
	generation := th.beginLoop("se-one")
	results := make(chan bool, 2)
	go func() {
		results <- th.tryReservePush(
			context.Background(), "se-one", "token", false, generation,
		)
	}()
	<-st.started
	go func() {
		results <- th.tryReservePush(
			context.Background(), "se-one", "token", false, generation,
		)
	}()
	close(st.release)
	admitted := 0
	for range 2 {
		if <-results {
			admitted++
		}
	}
	if admitted != 1 {
		t.Fatalf("same-device concurrent admissions = %d, want 1", admitted)
	}
	if calls := st.callCount("se-one"); calls != 1 {
		t.Fatalf("same-device durable reservations = %d, want 1", calls)
	}
	th.mu.Lock()
	retainedLocks := len(th.reservationLocks)
	th.mu.Unlock()
	if retainedLocks != 0 {
		t.Fatalf("completed reservations retained %d per-device locks", retainedLocks)
	}
}

func TestCodeAttestReservationLeaseCoversPushDispatch(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(
		registry.New(logger), store.NewMemory(store.Config{}),
		ServerConfig{}, logger,
	)
	t.Cleanup(srv.Close)
	srv.codeAttestThrottle.backgroundPushCooldown = 0
	srv.codeAttestThrottle.retrySpacing = time.Millisecond
	srv.codeAttestThrottle.retryJitter = 0
	srv.codeAttestThrottle.maxAttempts = 1
	kPub, _, _, sePub := providerKeyMaterial(t)
	provider := newCodeAttestProvider(kPub, sePub)
	rotated := make(chan uint64, 1)
	srv.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error {
		go func() {
			rotated <- srv.codeAttestThrottle.beginLoop(sePub)
		}()
		select {
		case <-rotated:
			t.Fatal("loop ownership rotated before reserved push dispatch finished")
		case <-time.After(20 * time.Millisecond):
		}
		return nil
	}})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	srv.codeAttestLoop(ctx, provider.ID, provider)
	select {
	case generation := <-rotated:
		if generation == 0 {
			t.Fatal("rotation did not acquire ownership after push dispatch")
		}
	case <-time.After(time.Second):
		t.Fatal("reservation lease was not released after push dispatch")
	}
}

func TestCodeAttestLoopGenerationChurnRetainsNoSEKeys(t *testing.T) {
	th := newCodeAttestThrottle()
	const churn = 2000
	for i := range churn {
		seKey := fmt.Sprintf("se-loop-churn-%d", i)
		generation := th.beginLoop(seKey)
		th.endLoop(seKey, generation)
	}
	th.mu.Lock()
	generations := len(th.loopGenerations)
	tokens := len(th.loopTokens)
	th.mu.Unlock()
	if generations != 0 || tokens != 0 {
		t.Fatalf("loop churn retained per-SE state: generations=%d tokens=%d", generations, tokens)
	}
	if generation := th.loopGeneration.Load(); generation != churn {
		t.Fatalf("global loop generation = %d, want %d", generation, churn)
	}
}

func TestCodeAttestPushCooldownSurvivesCoordinatorRestart(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	first := newCodeAttestThrottle()
	first.store = st
	first.now = func() time.Time { return now }
	gen := first.beginLoop("se-restart")
	if !first.tryReservePush(context.Background(), "se-restart", "token", false, gen) {
		t.Fatal("initial durable push admission rejected")
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.codeAttestThrottle.now = func() time.Time { return now.Add(time.Minute) }
	srv.SeedCodeAttestCache(context.Background())
	restartedGeneration := srv.codeAttestThrottle.beginLoop("se-restart")
	if srv.codeAttestThrottle.tryReservePush(context.Background(), "se-restart", "token", false, restartedGeneration) {
		t.Fatal("restart forgot the persisted APNs cooldown")
	}
}

func TestCodeAttestNewTokenUsesIndependentBudgetAfterRestart(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	if ok, err := st.ReserveCodeAttestPushBudget(
		context.Background(), "se-rotated-after-restart",
		codeAttestTokenHash("old-token"), now,
		now.Add(20*time.Minute),
	); err != nil || !ok {
		t.Fatalf("seed old-token budget: ok=%v err=%v", ok, err)
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.codeAttestThrottle.now = func() time.Time { return now.Add(time.Minute) }
	srv.SeedCodeAttestCache(context.Background())
	generation := srv.codeAttestThrottle.beginLoop("se-rotated-after-restart")
	if !srv.codeAttestThrottle.tryReservePush(
		context.Background(), "se-rotated-after-restart",
		"new-token", false, generation,
	) {
		t.Fatal("seeded old-token cooldown blocked a new token after restart")
	}
	oldGeneration := srv.codeAttestThrottle.beginLoop(
		"se-rotated-after-restart",
	)
	if srv.codeAttestThrottle.tryReservePush(
		context.Background(), "se-rotated-after-restart",
		"old-token", false, oldGeneration,
	) {
		t.Fatal("new-token reservation erased the old-token cooldown after restart")
	}
}

func TestCodeAttestNovelTokenChurnHonorsPerDeviceFloor(t *testing.T) {
	th := newCodeAttestThrottle()
	cur := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return cur }
	th.budgetClearCooldown = 10 * time.Minute
	genA := th.beginLoop("se-token-churn")
	if !th.tryReservePush(
		context.Background(), "se-token-churn", "token-a", false, genA,
	) {
		t.Fatal("initial token was not admitted")
	}
	genB := th.rotateLoopAndClearPushBudget("se-token-churn")
	if !th.tryReservePush(
		context.Background(), "se-token-churn", "token-b", false, genB,
	) {
		t.Fatal("first genuine token rotation was not admitted")
	}
	cur = cur.Add(time.Minute)
	genC := th.rotateLoopAndClearPushBudget("se-token-churn")
	if th.tryReservePush(
		context.Background(), "se-token-churn", "token-c", false, genC,
	) {
		t.Fatal("novel token bypassed the per-device rotation floor")
	}
	cur = cur.Add(10 * time.Minute)
	if !th.tryReservePush(
		context.Background(), "se-token-churn", "token-c", false, genC,
	) {
		t.Fatal("novel token stayed blocked after the rotation floor elapsed")
	}
}

func TestCodeAttestLocalBudgetPreservesABACooldown(t *testing.T) {
	th := newCodeAttestThrottle()
	cur := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return cur }
	th.budgetClearCooldown = time.Minute
	genA := th.beginLoop("se-aba")
	if !th.tryReservePush(
		context.Background(), "se-aba", "token-a", false, genA,
	) {
		t.Fatal("initial token A was not admitted")
	}
	genB := th.rotateLoopAndClearPushBudget("se-aba")
	if !th.tryReservePush(
		context.Background(), "se-aba", "token-b", false, genB,
	) {
		t.Fatal("token B did not receive an independent budget")
	}
	cur = cur.Add(2 * time.Minute)
	genA = th.rotateLoopAndClearPushBudget("se-aba")
	if th.tryReservePush(
		context.Background(), "se-aba", "token-a", false, genA,
	) {
		t.Fatal("A-B-A rotation forgot token A's original cooldown")
	}
}

func TestCodeAttestTokenRotationInvalidatesLoopAndProofNotDeviceEvidence(t *testing.T) {
	th := newCodeAttestThrottle()
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return now }
	th.recordAttestedForProcess("se", "1.0", "old-token", "process")
	oldGeneration := th.beginLoop("se")
	th.invalidateReuse("se")
	newGeneration := th.rotateLoopAndClearPushBudget("se")
	if th.loopCurrent("se", oldGeneration) {
		t.Fatal("token rotation did not invalidate prior loop generation")
	}
	if !th.loopCurrent("se", newGeneration) {
		t.Fatal("new token loop does not own generation")
	}
	if th.reuseAttestation("se", "1.0", "old-token", "process") {
		t.Fatal("old-token application proof survived rotation")
	}
	// The throttle owns only application/APNs evidence. No operation above can
	// delete or mutate the independent provider device-evidence store.
	st := store.NewMemory(store.Config{})
	_, err := st.UpsertProviderTrustReuse(context.Background(), store.ProviderTrustReuse{
		SEPubKey: "se", Serial: "serial", TrustLevel: "hardware",
		HardwareProofVerifiedAt: now, EvidenceGeneration: 1,
	}, 0)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := st.ListProviderTrustReuse(context.Background())
	if err != nil || len(rows) != 1 || rows[0].SEPubKey != "se" {
		t.Fatalf("device evidence changed during token rotation: %+v, %v", rows, err)
	}
}
