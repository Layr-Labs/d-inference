package registry

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRequestProfileStampFirstWriteWins(t *testing.T) {
	rp := NewRequestProfile(time.Now().Add(-time.Millisecond), "coord-1", nil, 0)
	rp.Stamp(&rp.ParsedUS)
	first := rp.ParsedUS.Load()
	if first < 1 {
		t.Fatalf("stamp must be >= 1 µs, got %d", first)
	}
	time.Sleep(2 * time.Millisecond)
	rp.Stamp(&rp.ParsedUS)
	if got := rp.ParsedUS.Load(); got != first {
		t.Fatalf("second stamp overwrote first: %d != %d", got, first)
	}
	// Nil receiver and nil field are no-ops.
	var nilRP *RequestProfile
	nilRP.Stamp(&rp.ReservedUS)
	rp.Stamp(nil)
	if rp.ReservedUS.Load() != 0 {
		t.Fatal("nil receiver must not stamp")
	}
}

func TestRequestProfileStampAtZeroClampsToOne(t *testing.T) {
	t0 := time.Now()
	rp := NewRequestProfile(t0, "c", nil, 0)
	rp.StampAt(&rp.ParsedUS, t0)
	if got := rp.ParsedUS.Load(); got != 1 {
		t.Fatalf("stamp at t0 must store 1 (distinguishable from unset), got %d", got)
	}
}

func TestAttemptProfileTwoHalvesFinalizeExactlyOnce(t *testing.T) {
	var calls atomic.Int32
	rp := NewRequestProfile(time.Now(), "c", func(_ *RequestProfile, ap *AttemptProfile) {
		calls.Add(1)
	}, 0)
	ap := rp.NewAttempt("req-1", 0, "")
	ap.Mark(StampAttemptStart)
	if ap.Finalized() {
		t.Fatal("must not be finalized before any half completes")
	}
	ap.CompleteHandler()
	ap.CompleteHandler() // idempotent
	if ap.Finalized() || calls.Load() != 0 {
		t.Fatal("handler half alone must not finalize")
	}
	ap.CompleteTerminal()
	ap.CompleteTerminal() // idempotent
	if !ap.Finalized() {
		t.Fatal("both halves done must finalize")
	}
	if calls.Load() != 1 {
		t.Fatalf("finalize must run exactly once, ran %d", calls.Load())
	}
}

func TestAttemptProfileTerminalFirstThenHandler(t *testing.T) {
	var calls atomic.Int32
	rp := NewRequestProfile(time.Now(), "c", func(*RequestProfile, *AttemptProfile) { calls.Add(1) }, 0)
	ap := rp.NewAttempt("req-1", 0, "")
	ap.CompleteTerminal()
	if calls.Load() != 0 {
		t.Fatal("terminal alone must not finalize")
	}
	ap.CompleteHandler()
	if calls.Load() != 1 {
		t.Fatalf("expected one finalize, got %d", calls.Load())
	}
}

func TestAttemptProfileFallbackFinalizesWithoutTerminal(t *testing.T) {
	done := make(chan *AttemptProfile, 1)
	rp := NewRequestProfile(time.Now(), "c", func(_ *RequestProfile, ap *AttemptProfile) { done <- ap }, 20*time.Millisecond)
	ap := rp.NewAttempt("req-1", 0, "")
	ap.CompleteHandler() // arms the fallback
	select {
	case got := <-done:
		if got != ap {
			t.Fatal("wrong attempt finalized")
		}
		_, _, _, providerOutcome, _ := got.Outcome()
		if providerOutcome != "no_terminal" {
			t.Fatalf("fallback must record provider_outcome=no_terminal, got %q", providerOutcome)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("fallback timer did not finalize the attempt")
	}
}

func TestAttemptProfileFallbackStoppedWhenTerminalArrives(t *testing.T) {
	var calls atomic.Int32
	rp := NewRequestProfile(time.Now(), "c", func(*RequestProfile, *AttemptProfile) { calls.Add(1) }, 20*time.Millisecond)
	ap := rp.NewAttempt("req-1", 0, "")
	ap.CompleteHandler()
	ap.SetOutcome("success", "", "", "completed", "")
	ap.CompleteTerminal()
	time.Sleep(60 * time.Millisecond)
	if calls.Load() != 1 {
		t.Fatalf("fallback must not double-finalize: %d", calls.Load())
	}
	_, _, _, providerOutcome, _ := ap.Outcome()
	if providerOutcome != "completed" {
		t.Fatalf("first outcome must win, got %q", providerOutcome)
	}
}

func TestRequestProfileInlineAndOverflowAttempts(t *testing.T) {
	rp := NewRequestProfile(time.Now(), "c", nil, 0)
	var aps []*AttemptProfile
	for i := 0; i < profileAttemptInline+2; i++ {
		aps = append(aps, rp.NewAttempt("req", i, ""))
	}
	if rp.AttemptCount() != profileAttemptInline+2 {
		t.Fatalf("count = %d", rp.AttemptCount())
	}
	got := rp.Attempts()
	for i, ap := range got {
		if ap != aps[i] || ap.Index != i {
			t.Fatalf("attempt %d mismatch", i)
		}
	}
	if rp.LastAttempt() != aps[len(aps)-1] {
		t.Fatal("LastAttempt must return the most recent attempt")
	}
}

func TestAttemptProfileCopyPreDispatch(t *testing.T) {
	rp := NewRequestProfile(time.Now().Add(-time.Second), "c", nil, 0)
	primary := rp.NewAttempt("p", 0, "")
	primary.Mark(StampAttemptStart)
	primary.Mark(StampQueued)
	primary.Mark(StampDequeued)
	backup := rp.NewAttempt("b", 0, "p")
	backup.CopyPreDispatchFrom(primary)
	if backup.Get(StampQueued) != primary.Get(StampQueued) || backup.Get(StampDequeued) != primary.Get(StampDequeued) {
		t.Fatal("pre-dispatch stamps not copied")
	}
	if backup.Get(StampAttemptStart) != primary.Get(StampAttemptStart) {
		t.Fatal("attempt start not copied")
	}
}

func TestProviderProfileRawSizeAndOrdering(t *testing.T) {
	rp := NewRequestProfile(time.Now(), "c", nil, 0)
	ap := rp.NewAttempt("req", 0, "")
	if st := ap.SetProviderProfileRaw(nil); st != ProviderProfileAbsent {
		t.Fatalf("empty must be absent, got %v", st)
	}
	big := make([]byte, maxProviderProfileBytes+1)
	if st := ap.SetProviderProfileRaw(big); st != ProviderProfileTooLarge {
		t.Fatalf("oversize must be rejected before retention, got %v", st)
	}
	if raw, _ := ap.ProviderProfileRaw(); raw != nil {
		t.Fatal("oversize bytes must not be retained")
	}
	if st := ap.SetProviderProfileRaw([]byte(`{"schema":1}`)); st != ProviderProfileStored {
		t.Fatalf("first profile must be stored, got %v", st)
	}
	if st := ap.SetProviderProfileRaw([]byte(`{"schema":1,"x":2}`)); st != ProviderProfileDuplicate {
		t.Fatalf("second profile must be a duplicate, got %v", st)
	}
	ap.CompleteHandler()
	ap.CompleteTerminal()
	late := rp.NewAttempt("req2", 1, "")
	late.CompleteHandler()
	late.CompleteTerminal()
	if st := late.SetProviderProfileRaw([]byte(`{}`)); st != ProviderProfileLate {
		t.Fatalf("profile after finalize must be late, got %v", st)
	}
	if _, isLate := late.ProviderProfileRaw(); !isLate {
		t.Fatal("late flag must be recorded")
	}
}

func TestRequestProfileConcurrentStampsRaceFree(t *testing.T) {
	rp := NewRequestProfile(time.Now(), "c", nil, 0)
	ap := rp.NewAttempt("req", 0, "")
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				ap.Mark(StampFirstChunkIngress)
				ap.ChunksIn.Add(1)
				rp.Stamp(&rp.FirstFlushUS)
				rp.ChunksOut.Add(1)
			}
		}()
	}
	wg.Wait()
	if ap.ChunksIn.Load() != 800 || rp.ChunksOut.Load() != 800 {
		t.Fatal("counters lost updates")
	}
}

func TestFailedAttemptsAccounting(t *testing.T) {
	rp := NewRequestProfile(time.Now().Add(-time.Second), "c", nil, 0)
	a0 := rp.NewAttempt("a0", 0, "")
	a0.AttemptStartUS.Store(1_000)
	a0.WriteDoneUS.Store(1_500)
	a1 := rp.NewAttempt("a1", 1, "")
	a1.AttemptStartUS.Store(5_000)
	a1.WriteDoneUS.Store(5_500)
	a1.Winning.Store(true)
	n, us := rp.FailedAttempts()
	if n != 1 || us != 4_000 {
		t.Fatalf("failed attempts = %d/%dµs, want 1/4000", n, us)
	}
}

func TestAttemptProfileConcurrentHalvesFinalizeOnceAndArmNoTimer(t *testing.T) {
	for i := 0; i < 200; i++ {
		var calls atomic.Int32
		rp := NewRequestProfile(time.Now(), "c", func(*RequestProfile, *AttemptProfile) { calls.Add(1) }, 50*time.Millisecond)
		ap := rp.NewAttempt("r", 0, "")
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); ap.CompleteHandler() }()
		go func() { defer wg.Done(); ap.CompleteTerminal() }()
		wg.Wait()
		if calls.Load() != 1 {
			t.Fatalf("iteration %d: finalize ran %d times", i, calls.Load())
		}
		ap.mu.Lock()
		leaked := ap.fallback != nil
		ap.mu.Unlock()
		if leaked {
			t.Fatalf("iteration %d: fallback timer armed after finalization", i)
		}
	}
}

func TestAttemptProfileClaimSuppressesFallback(t *testing.T) {
	var calls atomic.Int32
	rp := NewRequestProfile(time.Now(), "c", func(*RequestProfile, *AttemptProfile) { calls.Add(1) }, 20*time.Millisecond)
	ap := rp.NewAttempt("r", 0, "")
	ap.ClaimTerminal()
	ap.CompleteHandler()
	time.Sleep(60 * time.Millisecond)
	if calls.Load() != 0 {
		t.Fatal("claimed terminal must suppress the no-terminal fallback")
	}
	ap.SetOutcome("success", "", "", "completed", "")
	ap.CompleteTerminal()
	if calls.Load() != 1 {
		t.Fatal("real terminal must finalize once")
	}
	if _, _, _, po, _ := ap.Outcome(); po != "completed" {
		t.Fatalf("provider outcome %q", po)
	}
}

func TestDispatchedAttemptsIgnoresPlaceholders(t *testing.T) {
	rp := NewRequestProfile(time.Now(), "c", nil, 0)
	q := rp.NewAttempt("queued", 0, "")
	q.Mark(StampQueued)
	d := rp.NewAttempt("dispatched", 0, "")
	d.Mark(StampWriteDone)
	d.Winning.Store(true)
	if rp.DispatchedAttempts() != 1 {
		t.Fatalf("dispatched = %d", rp.DispatchedAttempts())
	}
	if n, _ := rp.FailedAttempts(); n != 0 {
		t.Fatalf("queue placeholder must not count as a failed attempt: %d", n)
	}
}

func TestClaimTerminalIsExclusive(t *testing.T) {
	rp := NewRequestProfile(time.Now(), "c", nil, 0)
	ap := rp.NewAttempt("r", 0, "")
	if !ap.ClaimTerminal() {
		t.Fatal("first claim must own the terminal")
	}
	if ap.ClaimTerminal() {
		t.Fatal("a second terminal frame must not own the terminal")
	}
	var nilAP *AttemptProfile
	if nilAP.ClaimTerminal() {
		t.Fatal("nil attempt cannot be owned")
	}
}

func TestCompleteTerminalUnlessClaimedIsAtomicWithTheClaim(t *testing.T) {
	var calls atomic.Int32
	rp := NewRequestProfile(time.Now(), "c", func(*RequestProfile, *AttemptProfile) { calls.Add(1) }, 0)
	owned := rp.NewAttempt("owned", 0, "")
	owned.CompleteHandler()
	if !owned.ClaimTerminal() {
		t.Fatal("first claim must own")
	}
	if owned.CompleteTerminalUnlessClaimed() {
		t.Fatal("a claimed terminal must be left to its owner")
	}
	if calls.Load() != 0 || owned.Finalized() {
		t.Fatal("funnel must not finalize a claimed attempt")
	}
	owned.CompleteTerminal() // the owner closes it
	if calls.Load() != 1 {
		t.Fatalf("owner completion must finalize once, got %d", calls.Load())
	}
	free := rp.NewAttempt("free", 1, "")
	free.CompleteHandler()
	if !free.CompleteTerminalUnlessClaimed() {
		t.Fatal("an unclaimed terminal must be completed by the funnel")
	}
	if calls.Load() != 2 || !free.Finalized() {
		t.Fatal("funnel completion must finalize the unclaimed attempt")
	}
	if free.CompleteTerminalUnlessClaimed() {
		t.Fatal("a recorded terminal must not be completed twice")
	}
	twice := rp.NewAttempt("twice", 2, "")
	twice.CompleteTerminal()
	if twice.CompleteTerminalUnlessClaimed() || twice.Finalized() {
		t.Fatal("funnel completion after a direct completion must be a no-op, never a second terminal half")
	}
	if free.ClaimTerminal() != true {
		t.Fatal("a late provider frame may still claim (retention is flagged late, billing untouched)")
	}
	var nilAP *AttemptProfile
	if nilAP.CompleteTerminalUnlessClaimed() {
		t.Fatal("nil attempt cannot be completed")
	}
}
