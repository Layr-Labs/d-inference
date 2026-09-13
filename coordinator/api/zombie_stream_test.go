package api

import (
	"fmt"
	"testing"
	"time"
)

// deliverStrayChunk mirrors noteStrayChunk's success path: a stray chunk that
// decides to (re-)send is followed by markSent once the enqueue succeeded. The
// tracker itself only arms the short retry hold on the decision.
func deliverStrayChunk(z *zombieStreamCanceller, requestID string, at time.Time) strayChunkResult {
	res := z.strayChunk(requestID, at)
	if res.send {
		if idx := z.markSent(requestID, at); idx != res.resendIndex {
			panic(fmt.Sprintf("markSent index %d != decided index %d", idx, res.resendIndex))
		}
	}
	return res
}

// TestZombieStreamCancellerEscalatingSchedule pins the re-send schedule for a
// request an abandon path recorded: stray chunks re-send the cancel at +1 s,
// +3 s, +10 s after the FIRST cancel, then every 30 s.
func TestZombieStreamCancellerEscalatingSchedule(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	created, _ := z.record("req-1", "model-a", cancelCauseClientGonePost, t0)
	if !created {
		t.Fatal("first record should create the entry")
	}
	z.markSent("req-1", t0)

	steps := []struct {
		at   time.Duration
		send bool
		idx  int
	}{
		{100 * time.Millisecond, false, 0},
		{900 * time.Millisecond, false, 0},
		{time.Second, true, 1},
		{1500 * time.Millisecond, false, 0},
		{3 * time.Second, true, 2},
		{5 * time.Second, false, 0},
		{10 * time.Second, true, 3},
		{20 * time.Second, false, 0},
		{40 * time.Second, true, 4},
		{60 * time.Second, false, 0},
		{70 * time.Second, true, 4}, // steady regime: index capped
	}
	for _, st := range steps {
		res := deliverStrayChunk(z, "req-1", t0.Add(st.at))
		if res.send != st.send {
			t.Fatalf("at +%v: send=%v, want %v", st.at, res.send, st.send)
		}
		if res.send && res.resendIndex != st.idx {
			t.Fatalf("at +%v: resend_index=%d, want %d", st.at, res.resendIndex, st.idx)
		}
		if res.cause != cancelCauseClientGonePost {
			t.Fatalf("at +%v: cause=%q, want recorded cause", st.at, res.cause)
		}
	}
}

// TestZombieStreamCancellerLateFirstStrayChunkDoesNotBurst: a zombie whose
// chunks only start arriving after several schedule points (provider was
// blocked behind a cold load) gets ONE re-send, then the next future point.
func TestZombieStreamCancellerLateFirstStrayChunkDoesNotBurst(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	z.record("req-late", "m", cancelCauseHedgeLoser, t0)
	z.markSent("req-late", t0)

	if res := deliverStrayChunk(z, "req-late", t0.Add(5*time.Second)); !res.send || res.resendIndex != 1 {
		t.Fatalf("late first stray chunk: send=%v idx=%d, want send idx 1", res.send, res.resendIndex)
	}
	if res := deliverStrayChunk(z, "req-late", t0.Add(5100*time.Millisecond)); res.send {
		t.Fatal("+3 s point already passed must be skipped, not fired as a burst")
	}
	if res := deliverStrayChunk(z, "req-late", t0.Add(10*time.Second)); !res.send || res.resendIndex != 2 {
		t.Fatalf("+10 s: send=%v idx=%d, want send idx 2", res.send, res.resendIndex)
	}
}

// TestZombieStreamCancellerUnrecordedIdCancelsImmediately: a chunk for an id
// nobody abandoned is cancelled at once (resend_index 0, cause stray_chunk)
// and then follows the same schedule.
func TestZombieStreamCancellerUnrecordedIdCancelsImmediately(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	res := deliverStrayChunk(z, "bogus", t0)
	if !res.send || res.resendIndex != 0 || res.cause != cancelCauseStrayChunk {
		t.Fatalf("first stray chunk for unknown id: %+v", res)
	}
	if res := deliverStrayChunk(z, "bogus", t0.Add(500*time.Millisecond)); res.send {
		t.Fatal("second chunk within 1 s must not re-cancel")
	}
	if res := deliverStrayChunk(z, "bogus", t0.Add(time.Second)); !res.send || res.resendIndex != 1 {
		t.Fatalf("+1 s: %+v, want re-send index 1", res)
	}
}

// TestZombieStreamCancellerSendFailureRetriesQuickly: a failed send is retried
// on the next stray chunk after zombieResendRetry, not at the next schedule point.
func TestZombieStreamCancellerSendFailureRetriesQuickly(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	z.record("req-f", "m", cancelCauseFirstChunkTimeout, t0)
	z.markSent("req-f", t0)
	z.noteSendFailed("req-f", t0)
	if res := z.strayChunk("req-f", t0.Add(zombieResendRetry/2)); res.send {
		t.Fatal("retry must wait zombieResendRetry")
	}
	if res := z.strayChunk("req-f", t0.Add(zombieResendRetry)); !res.send || res.resendIndex != 1 {
		t.Fatalf("retry after failure: %+v", res)
	}
}

// TestZombieStreamCancellerUndeliveredCancelKeepsIndexZero: an abandon path
// whose enqueue failed never marks the entry sent. The decision to re-send on
// a stray chunk holds the entry for zombieResendRetry (a chunk burst yields
// one attempt) without advancing the schedule or the resend index; the first
// delivery — whenever it happens — is index 0 and only then does the
// escalating schedule start.
func TestZombieStreamCancellerUndeliveredCancelKeepsIndexZero(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	z.record("req-u", "m", cancelCauseClientGonePost, t0)
	z.noteSendFailed("req-u", t0) // abandon path's own send was refused

	if res := z.strayChunk("req-u", t0.Add(zombieResendRetry/2)); res.send {
		t.Fatal("retry must wait zombieResendRetry")
	}
	res := z.strayChunk("req-u", t0.Add(zombieResendRetry))
	if !res.send || res.resendIndex != 0 || res.cause != cancelCauseClientGonePost {
		t.Fatalf("first retry decision: %+v, want send idx 0 under the abandon cause", res)
	}
	// The decision alone holds the entry (one attempt per burst) ...
	if res := z.strayChunk("req-u", t0.Add(zombieResendRetry+time.Millisecond)); res.send {
		t.Fatal("a chunk inside the hold must not decide a second send")
	}
	// ... and a failed retry leaves it undelivered: still index 0 next time.
	z.noteSendFailed("req-u", t0.Add(zombieResendRetry))
	res = z.strayChunk("req-u", t0.Add(2*zombieResendRetry))
	if !res.send || res.resendIndex != 0 {
		t.Fatalf("second retry decision: %+v, want send idx 0 (nothing delivered yet)", res)
	}
	e := z.entries["req-u"]
	if e.sent != 0 {
		t.Fatalf("sent = %d before any successful enqueue, want 0", e.sent)
	}
	// Delivered: index 0, schedule anchored on the FIRST cancel time.
	if idx := z.markSent("req-u", t0.Add(2*zombieResendRetry)); idx != 0 {
		t.Fatalf("markSent index = %d, want 0 for the first delivered cancel", idx)
	}
	if e.sent != 1 {
		t.Fatalf("sent = %d after the delivered retry, want 1", e.sent)
	}
	if res := deliverStrayChunk(z, "req-u", t0.Add(900*time.Millisecond)); res.send {
		t.Fatal("+0.9 s: the +1 s schedule point has not arrived")
	}
	if res := deliverStrayChunk(z, "req-u", t0.Add(time.Second)); !res.send || res.resendIndex != 1 {
		t.Fatalf("+1 s: %+v, want re-send index 1", res)
	}
	if idx := z.markSent("never-recorded", t0); idx != -1 {
		t.Fatalf("markSent on an untracked id = %d, want -1", idx)
	}
}

// TestZombieStreamCancellerTerminalResolvesEntry: the provider terminal
// returns the entry (first cancel time, cause, model) exactly once.
func TestZombieStreamCancellerTerminalResolvesEntry(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	z.record("req-t", "model-x", cancelCauseClientGonePre, t0)
	z.markSent("req-t", t0)
	deliverStrayChunk(z, "req-t", t0.Add(200*time.Millisecond))

	e, ok := z.terminal("req-t")
	if !ok {
		t.Fatal("terminal should resolve a recorded entry")
	}
	if !e.firstCancelAt.Equal(t0) || e.cause != cancelCauseClientGonePre || e.model != "model-x" || e.strayChunks != 1 {
		t.Fatalf("entry = %+v", e)
	}
	if _, ok := z.terminal("req-t"); ok {
		t.Fatal("entry must be removed on terminal")
	}
	if _, ok := z.terminal("never"); ok {
		t.Fatal("unknown id must not resolve")
	}
	if z.size() != 0 {
		t.Fatalf("size = %d, want 0", z.size())
	}
}

// TestZombieStreamCancellerRecordIsIdempotentAndForgetOnlyDropsCreated: a
// second record for the same id neither resets the schedule nor creates, and
// forget after a non-creating record leaves the original entry alone.
func TestZombieStreamCancellerRecordIsIdempotent(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	z.record("req-i", "m", cancelCauseOverflow, t0)
	z.markSent("req-i", t0)
	created, _ := z.record("req-i", "m", cancelCauseHedgeLoser, t0.Add(time.Second))
	if created {
		t.Fatal("second record must not create")
	}
	e, ok := z.terminal("req-i")
	if !ok || e.cause != cancelCauseOverflow || !e.firstCancelAt.Equal(t0) {
		t.Fatalf("entry = %+v, want original cause and first cancel time", e)
	}
	// forget drops the entry.
	z.record("req-g", "m", cancelCauseOverflow, t0)
	z.forget("req-g")
	if z.size() != 0 {
		t.Fatal("forget must drop the entry")
	}
}

// TestZombieStreamCancellerSweepExpiresIdleEntries: an entry idle past
// zombieEntryTTL is returned as expired on the next touch, preserving its last
// stray-chunk time so the caller can report it as the terminal.
func TestZombieStreamCancellerSweepExpiresIdleEntries(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	z.record("req-a", "m", cancelCauseClientGonePost, t0)
	z.markSent("req-a", t0)
	deliverStrayChunk(z, "req-a", t0.Add(2*time.Second))
	z.record("req-b", "m", cancelCauseHedgeLoser, t0) // never any chunk

	// Still live just under the TTL (activity = last stray chunk at +2 s).
	if _, expired := z.record("other", "m", cancelCauseHedgeLoser, t0.Add(2*time.Second+zombieEntryTTL)); len(expired) != 1 {
		t.Fatalf("expected only req-b (idle since t0) expired, got %d", len(expired))
	}
	_, expired := z.record("other2", "m", cancelCauseHedgeLoser, t0.Add(3*time.Second+zombieEntryTTL))
	if len(expired) != 1 {
		t.Fatalf("expected req-a expired, got %d", len(expired))
	}
	if e := expired[0]; e.cause != cancelCauseClientGonePost || !e.lastStrayAt.Equal(t0.Add(2*time.Second)) {
		t.Fatalf("expired entry = %+v", e)
	}
	if _, ok := z.terminal("req-a"); ok {
		t.Fatal("expired entry must be gone")
	}
}

// TestZombieStreamCancellerBounded: the map never exceeds its cap; the
// least recently active entry is evicted and reported.
func TestZombieStreamCancellerBounded(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	evicted := 0
	for i := 0; i < zombieCancelMaxEntries+100; i++ {
		_, expired := z.record(fmt.Sprintf("req-%d", i), "m", cancelCauseHedgeLoser, t0.Add(time.Duration(i)*time.Millisecond))
		evicted += len(expired)
		if z.size() > zombieCancelMaxEntries {
			t.Fatalf("size %d exceeds cap", z.size())
		}
	}
	if evicted != 100 {
		t.Fatalf("evicted = %d, want 100", evicted)
	}
	// The oldest ids were the ones evicted.
	if _, ok := z.terminal("req-0"); ok {
		t.Fatal("req-0 should have been evicted first")
	}
	if _, ok := z.terminal(fmt.Sprintf("req-%d", zombieCancelMaxEntries+99)); !ok {
		t.Fatal("newest entry must survive")
	}
}

// TestStrayChunkWarnRateLimit: one Warn per provider per window, with the
// suppressed count carried onto the next allowed line; providers independent.
func TestStrayChunkWarnRateLimit(t *testing.T) {
	z := newZombieStreamCanceller()
	t0 := time.Now()
	if allow, n := z.allowStrayWarn("p1", t0); !allow || n != 0 {
		t.Fatalf("first warn: allow=%v n=%d", allow, n)
	}
	for i := 1; i <= 5; i++ {
		if allow, n := z.allowStrayWarn("p1", t0.Add(time.Duration(i)*time.Second)); allow || n != i {
			t.Fatalf("within window #%d: allow=%v n=%d", i, allow, n)
		}
	}
	if allow, n := z.allowStrayWarn("p2", t0.Add(time.Second)); !allow || n != 0 {
		t.Fatalf("other provider: allow=%v n=%d", allow, n)
	}
	if allow, n := z.allowStrayWarn("p1", t0.Add(strayChunkWarnEvery)); !allow || n != 5 {
		t.Fatalf("after window: allow=%v suppressed=%d, want allow with 5", allow, n)
	}
	if allow, n := z.allowStrayWarn("p1", t0.Add(strayChunkWarnEvery+time.Second)); allow || n != 1 {
		t.Fatalf("counter must reset after an allowed line: allow=%v n=%d", allow, n)
	}
}

func TestCancelEnqueueIsAtomicWithTerminalResolution(t *testing.T) {
	z := newZombieStreamCanceller()
	z.record("immediate-terminal", "m", cancelCauseClientGonePost, time.Now())
	enqueuing := make(chan struct{})
	finishEnqueue := make(chan struct{})
	sendDone := make(chan bool, 1)
	go func() {
		index, sent := z.send("immediate-terminal", func() bool {
			close(enqueuing)
			<-finishEnqueue
			return true
		})
		sendDone <- sent && index == 0
	}()
	<-enqueuing
	terminalStarted := make(chan struct{})
	terminalDone := make(chan zombieEntry, 1)
	go func() {
		close(terminalStarted)
		e, _ := z.terminal("immediate-terminal")
		terminalDone <- e
	}()
	<-terminalStarted
	// The provider may respond before enqueue returns; terminal correlation
	// must wait until successful acceptance and its timestamp are recorded.
	select {
	case <-terminalDone:
		close(finishEnqueue)
		<-sendDone
		t.Fatal("terminal removed the entry before the successful enqueue was marked")
	case <-time.After(20 * time.Millisecond):
	}
	close(finishEnqueue)
	if !<-sendDone {
		t.Fatal("first successful enqueue was not recorded")
	}
	e := <-terminalDone
	if e.sent != 1 || e.firstSentAt.IsZero() {
		t.Fatalf("immediate terminal classified delivered enqueue as unsent: %+v", e)
	}
}

func TestCancelEvictedEntryStillReceivesBestEffortSend(t *testing.T) {
	z := newZombieStreamCanceller()
	z.record("evicted", "m", cancelCauseClientGonePost, time.Now())
	z.forget("evicted") // a bounded-map eviction before the abandon path resumes
	called := false
	index, sent := z.send("evicted", func() bool {
		called = true
		return true
	})
	if !called || !sent || index != -1 {
		t.Fatalf("untracked best-effort send = (%d, %v), called=%v", index, sent, called)
	}
}
