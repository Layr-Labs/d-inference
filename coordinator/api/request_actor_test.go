package api

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// newTestActor builds a requestActor wired to a real in-memory settlement store
// with a SYNCHRONOUS journal runner, so the durable journal is exercised for
// real and its rows are observable deterministically. Pass st == nil to disable
// journaling entirely (used by the concurrency stress tests, which only assert
// the in-memory CAS). journalErrs collects any store-journal error so happy-path
// tests can assert the store invariants passed.
func newTestActor(t *testing.T, tbl *actorTable, st store.SettlementStore) (*requestActor, *[]string) {
	t.Helper()
	if tbl == nil {
		tbl = newActorTable()
	}
	var mu sync.Mutex
	errs := &[]string{}
	a := &requestActor{
		logicalID:       "req-" + uuid.NewString(),
		table:           tbl,
		store:           st,
		journal:         func(op func()) { op() },
		consumerAccount: "acct-consumer",
		model:           "test-model",
		publicModel:     "test-model",
		endpoint:        "chat_completions",
		stream:          true,
		budgetMS:        600000,
		attempts:        make(map[string]*attemptSlot),
	}
	a.onJournalErr = func(op string, err error) {
		mu.Lock()
		*errs = append(*errs, op+": "+err.Error())
		mu.Unlock()
	}
	return a, errs
}

// --- Race #1: first decoded terminal wins, regardless of goroutine scheduling ---

func TestActorFirstTerminalWinsBothWireOrders(t *testing.T) {
	// error-then-complete: the error is decoded first, so it wins; the later
	// completion is rejected (telemetry only).
	a, _ := newTestActor(t, nil, nil)
	a.registerAttempt("A", "prov-1", "primary", 0)
	if !a.claimAttemptTerminal("A", terminalError) {
		t.Fatal("first error terminal must be accepted")
	}
	if a.claimAttemptTerminal("A", terminalComplete) {
		t.Fatal("later completion must lose to the earlier error")
	}

	// complete-then-error: the completion is decoded first, so it wins; the later
	// error is rejected. Same rule, opposite order — the OUTCOME follows CALL
	// ORDER, not which handler is slower.
	b, _ := newTestActor(t, nil, nil)
	b.registerAttempt("A", "prov-1", "primary", 0)
	if !b.claimAttemptTerminal("A", terminalComplete) {
		t.Fatal("first completion terminal must be accepted")
	}
	if b.claimAttemptTerminal("A", terminalError) {
		t.Fatal("later error must lose to the earlier completion")
	}
}

func TestActorConcurrentTerminalsExactlyOneWins(t *testing.T) {
	// Two goroutines claim complete/error for the same attempt at maximum
	// concurrency. Regardless of Go's scheduling, exactly one must win — this is
	// the actual regression guard for incident race #1. Run under -race.
	for i := 0; i < 2000; i++ {
		a, _ := newTestActor(t, nil, nil)
		a.registerAttempt("A", "prov-1", "primary", 0)
		start := make(chan struct{})
		var acceptedComplete, acceptedError bool
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			acceptedComplete = a.claimAttemptTerminal("A", terminalComplete)
		}()
		go func() {
			defer wg.Done()
			<-start
			acceptedError = a.claimAttemptTerminal("A", terminalError)
		}()
		close(start)
		wg.Wait()
		if acceptedComplete == acceptedError {
			t.Fatalf("iter %d: exactly one terminal must win; got complete=%v error=%v",
				i, acceptedComplete, acceptedError)
		}
	}
}

// --- Race #2: a client timeout firing concurrently with terminal acceptance ---

func TestActorTimeoutVsCompletionExactlyOneWins(t *testing.T) {
	// The client-facing timeout timer and the provider's completion race for the
	// SAME attempt terminal. Exactly one wins under the mutex, so billing and the
	// client outcome can never disagree: if the timeout wins, the completion is
	// rejected (no billing); if the completion wins, the timeout is rejected (the
	// client is never told it timed out). Run under -race.
	for i := 0; i < 2000; i++ {
		a, _ := newTestActor(t, nil, nil)
		a.registerAttempt("A", "prov-1", "primary", 0)
		start := make(chan struct{})
		var billed, toldTimeout bool
		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			<-start
			// The provider read loop: only a won claim proceeds to bill.
			billed = a.claimAttemptTerminal("A", terminalComplete)
		}()
		go func() {
			defer wg.Done()
			<-start
			// The client timer: only a won claim tells the client it timed out.
			toldTimeout = a.claimAttemptTerminal("A", terminalTimeout)
		}()
		close(start)
		wg.Wait()
		if billed == toldTimeout {
			t.Fatalf("iter %d: billing and timeout must be mutually exclusive; billed=%v toldTimeout=%v",
				i, billed, toldTimeout)
		}
	}
}

func TestServerActorAcceptsClientTimeoutGate(t *testing.T) {
	s := NewServer(registry.New(slog.Default()), store.NewMemory(store.Config{}), ServerConfig{}, slog.Default())

	// No actor bound for an attempt: the legacy always-timeout behavior is kept.
	if !s.actorAcceptsClientTimeout(&registry.PendingRequest{RequestID: "unbound"}) {
		t.Fatal("unbound attempt must keep legacy timeout behavior")
	}

	// A provider terminal already accepted: the timer must NOT contradict it.
	a, _ := newTestActor(t, s.actors, nil)
	a.registerAttempt("A", "prov-1", "primary", 0)
	if !a.claimAttemptTerminal("A", terminalComplete) {
		t.Fatal("provider completion should be accepted")
	}
	if s.actorAcceptsClientTimeout(&registry.PendingRequest{RequestID: "A"}) {
		t.Fatal("client timeout must be refused once a provider terminal won the attempt")
	}

	// A fresh attempt with no terminal yet: the timer may claim the timeout.
	b, _ := newTestActor(t, s.actors, nil)
	b.registerAttempt("B", "prov-1", "primary", 0)
	if !s.actorAcceptsClientTimeout(&registry.PendingRequest{RequestID: "B"}) {
		t.Fatal("client timeout should be accepted when no provider terminal has won")
	}
	// ...and having done so, the provider's later completion is superseded.
	if b.claimAttemptTerminal("B", terminalComplete) {
		t.Fatal("provider completion must lose to the already-accepted timeout")
	}
}

// TestAcceptProviderTerminalRejectDoesNotTouchPending is the regression guard for
// the complete-then-error hang: a superseded provider terminal must NOT call
// RemovePending, so it cannot race (and steal) the winning handler's own
// RemovePending — which would make handleComplete drop billing and hang the
// stream. Here the completion wins the claim; the later error is superseded, and
// the provider's pending record must remain intact for the winning handler.
func TestAcceptProviderTerminalRejectDoesNotTouchPending(t *testing.T) {
	s := NewServer(registry.New(slog.Default()), store.NewMemory(store.Config{}), ServerConfig{}, slog.Default())
	prov := s.registry.Register("prov-1", nil, &protocol.RegisterMessage{})
	pending := &registry.PendingRequest{RequestID: "A", ProviderID: "prov-1"}
	prov.AddPending(pending)

	a, _ := newTestActor(t, s.actors, nil)
	a.registerAttempt("A", "prov-1", "primary", 0)

	// Completion wins the claim (the read loop would launch handleComplete).
	if !s.acceptProviderTerminal("prov-1", prov, "A", terminalComplete) {
		t.Fatal("first completion terminal must be accepted")
	}
	// A later error for the same attempt is superseded — and must leave the
	// pending record for the winning handler to remove.
	if s.acceptProviderTerminal("prov-1", prov, "A", terminalError) {
		t.Fatal("superseded error must be rejected")
	}
	if prov.GetPending("A") == nil {
		t.Fatal("reject path must NOT remove the pending record (the winning handler owns it)")
	}
}

// --- Race #3 / speculative: exactly one durable winner; loser never settles ---

func TestActorSpeculativeSingleWinnerLoserNeverSettles(t *testing.T) {
	st := store.NewMemory(store.Config{})
	a, jerrs := newTestActor(t, nil, st)
	ctx := context.Background()

	a.registerAttempt("A", "prov-1", "primary", 0)
	a.registerAttempt("B", "prov-2", "backup", 0)

	if !a.selectWinner("A") {
		t.Fatal("primary must win the winner CAS")
	}
	if a.selectWinner("B") {
		t.Fatal("backup must lose the winner CAS")
	}

	// The loser's later provider completion is rejected: it can never settle.
	if a.claimAttemptTerminal("B", terminalComplete) {
		t.Fatal("speculative loser terminal must be rejected")
	}
	// The winner's completion is accepted.
	if !a.claimAttemptTerminal("A", terminalComplete) {
		t.Fatal("winner completion must be accepted")
	}

	// The durable journal mirrors the decision.
	reqRow, err := st.GetRequestSettlement(ctx, a.logicalID)
	if err != nil {
		t.Fatalf("request row: %v", err)
	}
	if reqRow.WinnerAttemptID != "A" {
		t.Fatalf("journal winner = %q, want A", reqRow.WinnerAttemptID)
	}
	loser, err := st.GetRequestAttempt(ctx, a.logicalID, "B")
	if err != nil {
		t.Fatalf("loser row: %v", err)
	}
	if loser.Disposition != store.AttemptDispositionSpeculativeLoser {
		t.Fatalf("loser disposition = %q, want speculative_loser", loser.Disposition)
	}
	if _, err := st.GetAttemptTerminal(ctx, a.logicalID, "B"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("loser must have no accepted terminal in the journal, got err=%v", err)
	}
	if _, err := st.GetAttemptTerminal(ctx, a.logicalID, "A"); err != nil {
		t.Fatalf("winner terminal should be journaled: %v", err)
	}
	if len(*jerrs) != 0 {
		t.Fatalf("journal must have no errors on the happy path, got %v", *jerrs)
	}
}

func TestActorConcurrentWinnerCASExactlyOne(t *testing.T) {
	// Primary and backup produce first output concurrently. Exactly one may win;
	// the loser's later terminal must be rejected. Run under -race.
	for i := 0; i < 2000; i++ {
		a, _ := newTestActor(t, nil, nil)
		a.registerAttempt("A", "prov-1", "primary", 0)
		a.registerAttempt("B", "prov-2", "backup", 0)
		start := make(chan struct{})
		var wonA, wonB bool
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); <-start; wonA = a.selectWinner("A") }()
		go func() { defer wg.Done(); <-start; wonB = a.selectWinner("B") }()
		close(start)
		wg.Wait()
		if wonA == wonB {
			t.Fatalf("iter %d: exactly one winner; wonA=%v wonB=%v", i, wonA, wonB)
		}
		loserID := "A"
		if wonA {
			loserID = "B"
		}
		if a.claimAttemptTerminal(loserID, terminalComplete) {
			t.Fatalf("iter %d: loser %s terminal must be rejected", i, loserID)
		}
	}
}

// --- Invariant 4: a failed attempt with an active eligible peer waits ---

func TestActorFailedPrimaryWaitsForActiveBackup(t *testing.T) {
	st := store.NewMemory(store.Config{})
	a, jerrs := newTestActor(t, nil, st)

	a.registerAttempt("A", "prov-1", "primary", 0)
	a.registerAttempt("B", "prov-2", "backup", 0)

	// Primary fails. Its terminal is recorded, but it does NOT select a winner or
	// finalize the request while the backup remains eligible.
	if !a.claimAttemptTerminal("A", terminalError) {
		t.Fatal("primary error terminal must be accepted")
	}
	a.mu.Lock()
	winner := a.winner
	a.mu.Unlock()
	if winner != "" {
		t.Fatalf("failed primary must not select a winner; winner=%q", winner)
	}
	if !a.hasActivePeer("A") {
		t.Fatal("backup must still be an active eligible peer")
	}

	// The backup can still win and settle.
	if !a.selectWinner("B") {
		t.Fatal("active backup must be able to win after the primary failed")
	}
	if !a.claimAttemptTerminal("B", terminalComplete) {
		t.Fatal("backup completion must be accepted")
	}
	if len(*jerrs) != 0 {
		t.Fatalf("journal errors: %v", *jerrs)
	}
}

// --- Late / duplicate terminals are no-ops ---

func TestActorLateDuplicateTerminalIsNoOp(t *testing.T) {
	a, _ := newTestActor(t, nil, nil)
	a.registerAttempt("A", "prov-1", "primary", 0)

	if !a.claimAttemptTerminal("A", terminalComplete) {
		t.Fatal("first terminal accepted")
	}
	// Duplicate of the same kind, a different kind, a disconnect, and a cancel:
	// all superseded after a decision was made.
	for _, k := range []terminalKind{terminalComplete, terminalError, terminalDisconnect, terminalCancel} {
		if a.claimAttemptTerminal("A", k) {
			t.Fatalf("late %s terminal must be a no-op", k)
		}
	}
	// An unknown attempt is also refused (never suppresses nor invents a claim).
	if a.claimAttemptTerminal("unknown", terminalComplete) {
		t.Fatal("terminal for an unregistered attempt must be refused")
	}
}

// --- retryReleaseWinner: release an invisible failed winner, then replace it ---

func TestActorRetryReleaseWinnerAndReplace(t *testing.T) {
	st := store.NewMemory(store.Config{})
	a, jerrs := newTestActor(t, nil, st)
	ctx := context.Background()

	a.registerAttempt("A", "prov-1", "primary", 0)
	if !a.selectWinner("A") {
		t.Fatal("A must win")
	}
	// A clean completion may NOT be released for retry.
	if !a.claimAttemptTerminal("A", terminalError) {
		t.Fatal("winner error terminal accepted")
	}
	if !a.retryReleaseWinner("A") {
		t.Fatal("a failed invisible winner must be releasable for retry")
	}
	// Winner cleared and epoch advanced.
	a.mu.Lock()
	winner, epoch := a.winner, a.winnerEpoch
	a.mu.Unlock()
	if winner != "" || epoch != 1 {
		t.Fatalf("after release winner=%q epoch=%d, want \"\"/1", winner, epoch)
	}
	// A replacement attempt can now be created and win.
	a.registerAttempt("A2", "prov-3", "primary", 1)
	if !a.selectWinner("A2") {
		t.Fatal("replacement attempt must win after release")
	}
	if !a.claimAttemptTerminal("A2", terminalComplete) {
		t.Fatal("replacement completion accepted")
	}

	reqRow, err := st.GetRequestSettlement(ctx, a.logicalID)
	if err != nil {
		t.Fatalf("request row: %v", err)
	}
	if reqRow.WinnerAttemptID != "A2" {
		t.Fatalf("journal winner = %q, want A2", reqRow.WinnerAttemptID)
	}
	if len(*jerrs) != 0 {
		t.Fatalf("journal errors: %v", *jerrs)
	}
}

func TestActorRetryReleaseRejectsCleanWinner(t *testing.T) {
	a, _ := newTestActor(t, nil, nil)
	a.registerAttempt("A", "prov-1", "primary", 0)
	a.selectWinner("A")
	// No terminal yet: nothing to release.
	if a.retryReleaseWinner("A") {
		t.Fatal("winner without a terminal must not be released")
	}
	// A clean completion is absorbing: never released for retry.
	a.claimAttemptTerminal("A", terminalComplete)
	if a.retryReleaseWinner("A") {
		t.Fatal("a cleanly completed winner must not be released for retry")
	}
}

// --- fence freezes winner selection ---

func TestActorFenceBlocksWinnerSelection(t *testing.T) {
	st := store.NewMemory(store.Config{})
	a, jerrs := newTestActor(t, nil, st)

	a.registerAttempt("A", "prov-1", "primary", 0)
	if !a.fence("client_cancelled") {
		t.Fatal("first fence must succeed")
	}
	if a.fence("client_cancelled") {
		t.Fatal("second fence is idempotent (no re-fence)")
	}
	if a.selectWinner("A") {
		t.Fatal("no winner may be selected after a fence")
	}
	if len(*jerrs) != 0 {
		t.Fatalf("journal errors: %v", *jerrs)
	}
}

// --- the read-loop passthrough helper is legacy-safe when no actor is bound ---

func TestAcceptProviderTerminalLegacyPassthrough(t *testing.T) {
	s := NewServer(registry.New(slog.Default()), store.NewMemory(store.Config{}), ServerConfig{}, slog.Default())
	// No actor bound for this attempt: the read loop proceeds exactly as before
	// the actor existed (returns true). provider may be nil on this path.
	if !s.acceptProviderTerminal("prov-1", nil, "unbound-attempt", terminalComplete) {
		t.Fatal("an attempt with no bound actor must fall back to the legacy path")
	}
}
