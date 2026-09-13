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
		rotated <- th.rotateLoopAndClearPushBudget(context.Background(), "se-rotate")
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
	if err != nil || len(rows) != 2 { // token row + admission-floor sentinel
		t.Fatalf("zero-cooldown durable reservation = %+v, err=%v", rows, err)
	}
	for _, row := range rows {
		if !row.NextPushAt.After(now) {
			t.Fatalf("zero cooldown produced a non-future reservation window: %+v", row)
		}
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

// Codex P1 (durable half): the novel-token admission floor survives a
// coordinator restart, so a reconnect churn of fabricated tokens cannot mint
// immediate pushes against a fresh instance. The novel token waits out the
// seeded floor, then admits; the old token stays on its own exact cooldown
// (A-B-A retention).
func TestCodeAttestNovelTokenAfterRestartWaitsForSeededFloor(t *testing.T) {
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
	cur := now.Add(time.Minute)
	srv.codeAttestThrottle.now = func() time.Time { return cur }
	srv.SeedCodeAttestCache(context.Background())
	generation := srv.codeAttestThrottle.beginLoop("se-rotated-after-restart")
	if srv.codeAttestThrottle.tryReservePush(
		context.Background(), "se-rotated-after-restart",
		"new-token", false, generation,
	) {
		t.Fatal("novel token bypassed the seeded per-device admission floor after restart")
	}
	oldGeneration := srv.codeAttestThrottle.beginLoop(
		"se-rotated-after-restart",
	)
	if srv.codeAttestThrottle.tryReservePush(
		context.Background(), "se-rotated-after-restart",
		"old-token", false, oldGeneration,
	) {
		t.Fatal("restart forgot the old token's exact cooldown")
	}
	cur = now.Add(21 * time.Minute)
	lateGeneration := srv.codeAttestThrottle.beginLoop(
		"se-rotated-after-restart",
	)
	if !srv.codeAttestThrottle.tryReservePush(
		context.Background(), "se-rotated-after-restart",
		"new-token", false, lateGeneration,
	) {
		t.Fatal("novel token stayed blocked after the seeded floor elapsed")
	}
}

func TestCodeAttestNovelTokenChurnHonorsPerDeviceFloor(t *testing.T) {
	th := newCodeAttestThrottle()
	cur := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return cur }
	th.budgetClearCooldown = 10 * time.Minute
	th.backgroundPushCooldown = 10 * time.Minute
	genA := th.beginLoop("se-token-churn")
	if !th.tryReservePush(
		context.Background(), "se-token-churn", "token-a", false, genA,
	) {
		t.Fatal("initial token was not admitted")
	}
	genB := th.rotateLoopAndClearPushBudget(context.Background(), "se-token-churn")
	if !th.tryReservePush(
		context.Background(), "se-token-churn", "token-b", false, genB,
	) {
		t.Fatal("first genuine token rotation was not admitted")
	}
	cur = cur.Add(time.Minute)
	genC := th.rotateLoopAndClearPushBudget(context.Background(), "se-token-churn")
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
	genB := th.rotateLoopAndClearPushBudget(context.Background(), "se-aba")
	if !th.tryReservePush(
		context.Background(), "se-aba", "token-b", false, genB,
	) {
		t.Fatal("token B did not receive an independent budget")
	}
	cur = cur.Add(2 * time.Minute)
	genA = th.rotateLoopAndClearPushBudget(context.Background(), "se-aba")
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
	th.recordAttestedForProcess("se", "1.0", "old-token", "process", trHashA)
	oldGeneration := th.beginLoop("se")
	th.invalidateReuse("se")
	newGeneration := th.rotateLoopAndClearPushBudget(context.Background(), "se")
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

// Codex P1 acceptance: a provider reconnecting rapidly with a fresh fabricated
// APNs token per registration (beginLoop path — no rotation allowance) gets
// exactly ONE immediate push; every further novel token is paced by the
// per-SE-key admission floor, and both durable rows and in-memory budget maps
// stay bounded.
func TestCodeAttestReconnectTokenChurnPacedByAdmissionFloor(t *testing.T) {
	st := store.NewMemory(store.Config{})
	th := newCodeAttestThrottle()
	th.store = st
	cur := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return cur }
	const se = "se-reconnect-churn"
	ctx := context.Background()

	admitted := 0
	for i := range 20 {
		generation := th.beginLoop(se)
		if th.tryReservePush(
			ctx, se, fmt.Sprintf("fabricated-token-%d", i), false, generation,
		) {
			admitted++
		}
	}
	if admitted != 1 {
		t.Fatalf("rapid reconnect churn admissions = %d, want 1 immediate push", admitted)
	}
	rows, err := st.ListCodeAttestPushBudgets(ctx)
	if err != nil || len(rows) != 2 { // one token row + the floor sentinel
		t.Fatalf("token churn minted durable budget rows: %+v, err=%v", rows, err)
	}

	// Once the floor elapses, exactly one more novel token is admitted.
	cur = cur.Add(th.backgroundPushCooldown)
	admitted = 0
	for i := range 5 {
		generation := th.beginLoop(se)
		if th.tryReservePush(
			ctx, se, fmt.Sprintf("late-token-%d", i), false, generation,
		) {
			admitted++
		}
	}
	if admitted != 1 {
		t.Fatalf("post-floor churn admissions = %d, want 1", admitted)
	}

	// Long-run floor-paced churn keeps durable rows and in-memory maps bounded.
	for i := range 3 * store.CodeAttestPushBudgetMaxTokenRows {
		cur = cur.Add(th.backgroundPushCooldown)
		generation := th.beginLoop(se)
		if !th.tryReservePush(
			ctx, se, fmt.Sprintf("slow-token-%d", i), false, generation,
		) {
			t.Fatalf("floor-spaced push %d was denied", i)
		}
	}
	rows, err = st.ListCodeAttestPushBudgets(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tokenRows := 0
	for _, row := range rows {
		if row.TokenHash != "" {
			tokenRows++
		}
	}
	if tokenRows > store.CodeAttestPushBudgetMaxTokenRows ||
		len(rows) > store.CodeAttestPushBudgetMaxTokenRows+1 {
		t.Fatalf("durable budget rows unbounded: tokens=%d total=%d", tokenRows, len(rows))
	}
	th.mu.Lock()
	inMemory := len(th.lastPush) + len(th.durableNextPush)
	th.mu.Unlock()
	if inMemory > 2*store.CodeAttestPushBudgetMaxTokenRows {
		t.Fatalf("in-memory budget maps unbounded: %d entries", inMemory)
	}
}

// A genuine (heartbeat-rotation) budget clear lifts the DURABLE admission floor
// too, so the rotated token is challenged promptly even against the durable
// gate — preserving Codex #9 while the floor blocks registration churn.
func TestCodeAttestGenuineRotationClearsDurableFloor(t *testing.T) {
	st := store.NewMemory(store.Config{})
	th := newCodeAttestThrottle()
	th.store = st
	cur := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	th.now = func() time.Time { return cur }
	const se = "se-genuine-rotation"

	generation := th.beginLoop(se)
	if !th.tryReservePush(context.Background(), se, "token-a", false, generation) {
		t.Fatal("initial token was not admitted")
	}
	rotated := th.rotateLoopAndClearPushBudget(context.Background(), se)
	if !th.tryReservePush(context.Background(), se, "token-b", false, rotated) {
		t.Fatal("genuinely rotated token was blocked by the durable admission floor")
	}
}

// Codex 06:36Z P1: the genuine-rotation floor clear is throttled by a DURABLE
// cooldown, not just the process-local lastBudgetClear map. A coordinator
// restart (fresh throttle over the same store) whose durable state records a
// recent clear must NOT clear the floor again — otherwise a provider could
// reconnect with one token and heartbeat another once per deploy for an
// immediate push. After the cooldown elapses, rotation clears work again.
func TestCodeAttestRotationClearCooldownSurvivesRestart(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	const se = "se-restart-rotation"
	ctx := context.Background()

	first := newCodeAttestThrottle()
	first.store = st
	first.now = func() time.Time { return now }
	generation := first.beginLoop(se)
	if !first.tryReservePush(ctx, se, "token-a", false, generation) {
		t.Fatal("initial token was not admitted")
	}
	// Genuine rotation: honored immediately (quiet period), spends the durable
	// clear budget, and the rotated token pushes right away (Codex #9 UX).
	rotated := first.rotateLoopAndClearPushBudget(ctx, se)
	if !first.tryReservePush(ctx, se, "token-b", false, rotated) {
		t.Fatal("genuinely rotated token was not admitted")
	}

	// RESTART: a fresh throttle over the SAME store one minute later has an
	// empty lastBudgetClear map, but the durable last-clear is recent.
	cur := now.Add(time.Minute)
	second := newCodeAttestThrottle()
	second.store = st
	second.now = func() time.Time { return cur }
	rotatedAfterRestart := second.rotateLoopAndClearPushBudget(ctx, se)
	if second.tryReservePush(ctx, se, "token-c", false, rotatedAfterRestart) {
		t.Fatal("restart re-granted the rotation floor clear within the durable cooldown")
	}

	// Once the durable cooldown elapses, a rotation clear is honored again.
	cur = now.Add(second.budgetClearCooldown + time.Minute)
	lateRotation := second.rotateLoopAndClearPushBudget(ctx, se)
	if !second.tryReservePush(ctx, se, "token-c", false, lateRotation) {
		t.Fatal("rotation clear stayed blocked after the durable cooldown elapsed")
	}
}

// Codex 06:36Z P1 (blue-green half): two live throttle instances over one
// store share the durable clear budget — only one rotation clear is honored
// within the window, and the loser's novel token stays paced.
func TestCodeAttestRotationClearAdmitsOnceAcrossPeers(t *testing.T) {
	st := store.NewMemory(store.Config{})
	cur := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	const se = "se-blue-green-rotation"
	ctx := context.Background()

	blue := newCodeAttestThrottle()
	blue.store = st
	blue.now = func() time.Time { return cur }
	green := newCodeAttestThrottle()
	green.store = st
	green.now = func() time.Time { return cur }

	generation := blue.beginLoop(se)
	if !blue.tryReservePush(ctx, se, "token-a", false, generation) {
		t.Fatal("initial token was not admitted")
	}
	cur = cur.Add(time.Minute)
	clearedBlue := blue.clearPushBudget(ctx, se)
	clearedGreen := green.clearPushBudget(ctx, se)
	if !clearedBlue || clearedGreen {
		t.Fatalf("rotation clears across peers = blue:%v green:%v, want exactly the first",
			clearedBlue, clearedGreen)
	}
	// The loser's novel token stays blocked for the rest of the window...
	greenGeneration := green.beginLoop(se)
	if green.tryReservePush(ctx, se, "token-b", false, greenGeneration) {
		t.Fatal("throttled peer still minted an immediate novel-token push")
	}
	// ...and the shared durable cooldown governs both peers going forward.
	cur = cur.Add(green.budgetClearCooldown)
	if !green.clearPushBudget(ctx, se) {
		t.Fatal("peer rotation clear stayed blocked after the shared cooldown elapsed")
	}
}
