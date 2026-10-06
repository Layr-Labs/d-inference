package inference_test

import (
	"fmt"
	"testing"
	"time"

	cancellation "github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
)

// deliverStrayChunk mirrors noteStrayChunk's success path: a stray chunk that
// decides to (re-)send is followed by markSent once the enqueue succeeded. The
// tracker itself only arms the short retry hold on the decision.
func deliverStrayChunk(z *zombieFixture, requestID string, at time.Time) cancellation.Decision {
	res := z.StrayChunk(requestID, at)
	if res.Send {
		if idx := z.MarkSent(requestID, at); idx != res.ResendIndex {
			panic(fmt.Sprintf("markSent index %d != decided index %d", idx, res.ResendIndex))
		}
	}
	return res
}

// TestZombieStreamCancellerEscalatingSchedule pins the re-send schedule for a
// request an abandon path recorded: stray chunks re-send the cancel at +1 s,
// +3 s, +10 s after the FIRST cancel, then every 30 s.
func TestZombieStreamCancellerEscalatingSchedule(t *testing.T) {
	z := newZombieFixture()

	t0 := time.Now()
	created, _ := z.Record("req-1", "model-a", cancellation.CauseClientGonePost, t0)
	if !created {
		t.Fatal("first record should create the entry")
	}
	z.MarkSent("req-1", t0)

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
		if res.Send != st.send {
			t.Fatalf("at +%v: send=%v, want %v", st.at, res.Send, st.send)
		}
		if res.Send && res.ResendIndex != st.idx {
			t.Fatalf("at +%v: resend_index=%d, want %d", st.at, res.ResendIndex, st.idx)
		}
		if res.Cause != cancellation.CauseClientGonePost {
			t.Fatalf("at +%v: cause=%q, want recorded cause", st.at, res.Cause)
		}
	}
}

// TestZombieStreamCancellerLateFirstStrayChunkDoesNotBurst: a zombie whose
// chunks only start arriving after several schedule points (provider was
// blocked behind a cold load) gets ONE re-send, then the next future point.
func TestZombieStreamCancellerLateFirstStrayChunkDoesNotBurst(t *testing.T) {
	z := newZombieFixture()

	t0 := time.Now()
	z.Record("req-late", "m", cancellation.CauseHedgeLoser, t0)
	z.MarkSent("req-late", t0)

	if res := deliverStrayChunk(z, "req-late", t0.Add(5*time.Second)); !res.Send || res.ResendIndex != 1 {
		t.Fatalf("late first stray chunk: send=%v idx=%d, want send idx 1", res.Send, res.ResendIndex)
	}
	if res := deliverStrayChunk(z, "req-late", t0.Add(5100*time.Millisecond)); res.Send {
		t.Fatal("+3 s point already passed must be skipped, not fired as a burst")
	}
	if res := deliverStrayChunk(z, "req-late", t0.Add(10*time.Second)); !res.Send || res.ResendIndex != 2 {
		t.Fatalf("+10 s: send=%v idx=%d, want send idx 2", res.Send, res.ResendIndex)
	}
}

// TestZombieStreamCancellerUnrecordedIdCancelsImmediately: a chunk for an id
// nobody abandoned is cancelled at once (resend_index 0, cause stray_chunk)
// and then follows the same schedule.
func TestZombieStreamCancellerUnrecordedIdCancelsImmediately(t *testing.T) {
	z := newZombieFixture()

	t0 := time.Now()
	res := deliverStrayChunk(z, "bogus", t0)
	if !res.Send || res.ResendIndex != 0 || res.Cause != cancellation.CauseStrayChunk {
		t.Fatalf("first stray chunk for unknown id: %+v", res)
	}
	if res := deliverStrayChunk(z, "bogus", t0.Add(500*time.Millisecond)); res.Send {
		t.Fatal("second chunk within 1 s must not re-cancel")
	}
	if res := deliverStrayChunk(z, "bogus", t0.Add(time.Second)); !res.Send || res.ResendIndex != 1 {
		t.Fatalf("+1 s: %+v, want re-send index 1", res)
	}
}

// TestZombieStreamCancellerSendFailureRetriesQuickly: a failed send is retried
// on the next stray chunk after zombieResendRetry, not at the next schedule point.
func TestZombieStreamCancellerSendFailureRetriesQuickly(t *testing.T) {
	z := newZombieFixture()

	t0 := time.Now()
	z.Record("req-f", "m", cancellation.CauseFirstChunkTimeout, t0)
	z.MarkSent("req-f", t0)
	z.NoteSendFailed("req-f", t0)
	if res := z.StrayChunk("req-f", t0.Add(cancellation.ResendRetry/2)); res.Send {
		t.Fatal("retry must wait zombieResendRetry")
	}
	if res := z.StrayChunk("req-f", t0.Add(cancellation.ResendRetry)); !res.Send || res.ResendIndex != 1 {
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
	z := newZombieFixture()

	t0 := time.Now()
	z.Record("req-u", "m", cancellation.CauseClientGonePost, t0)
	z.NoteSendFailed("req-u", t0) // abandon path's own send was refused

	if res := z.StrayChunk("req-u", t0.Add(cancellation.ResendRetry/2)); res.Send {
		t.Fatal("retry must wait zombieResendRetry")
	}
	res := z.StrayChunk("req-u", t0.Add(cancellation.ResendRetry))
	if !res.Send || res.ResendIndex != 0 || res.Cause != cancellation.CauseClientGonePost {
		t.Fatalf("first retry decision: %+v, want send idx 0 under the abandon cause", res)
	}
	// The decision alone holds the entry (one attempt per burst) ...
	if res := z.StrayChunk("req-u", t0.Add(cancellation.ResendRetry+time.Millisecond)); res.Send {
		t.Fatal("a chunk inside the hold must not decide a second send")
	}
	// ... and a failed retry leaves it undelivered: still index 0 next time.
	z.NoteSendFailed("req-u", t0.Add(cancellation.ResendRetry))
	res = z.StrayChunk("req-u", t0.Add(2*cancellation.ResendRetry))
	if !res.Send || res.ResendIndex != 0 {
		t.Fatalf("second retry decision: %+v, want send idx 0 (nothing delivered yet)", res)
	}
	e := z.entries.Lookup("req-u")

	if e.Sent != 0 {
		t.Fatalf("sent = %d before any successful enqueue, want 0", e.Sent)
	}
	// Delivered: index 0, schedule anchored on the FIRST cancel time.
	if idx := z.MarkSent("req-u", t0.Add(2*cancellation.ResendRetry)); idx != 0 {
		t.Fatalf("markSent index = %d, want 0 for the first delivered cancel", idx)
	}
	if e.Sent != 1 {
		t.Fatalf("sent = %d after the delivered retry, want 1", e.Sent)
	}
	if res := deliverStrayChunk(z, "req-u", t0.Add(900*time.Millisecond)); res.Send {
		t.Fatal("+0.9 s: the +1 s schedule point has not arrived")
	}
	if res := deliverStrayChunk(z, "req-u", t0.Add(time.Second)); !res.Send || res.ResendIndex != 1 {
		t.Fatalf("+1 s: %+v, want re-send index 1", res)
	}
	if idx := z.MarkSent("never-recorded", t0); idx != -1 {
		t.Fatalf("markSent on an untracked id = %d, want -1", idx)
	}
}

// TestZombieStreamCancellerTerminalResolvesEntry: the provider terminal
// returns the entry (first cancel time, cause, model) exactly once.
func TestZombieStreamCancellerTerminalResolvesEntry(t *testing.T) {
	z := newZombieFixture()

	t0 := time.Now()
	z.Record("req-t", "model-x", cancellation.CauseClientGonePre, t0)
	z.MarkSent("req-t", t0)
	deliverStrayChunk(z, "req-t", t0.Add(200*time.Millisecond))

	e, ok := z.Terminal("req-t")
	if !ok {
		t.Fatal("terminal should resolve a recorded entry")
	}
	if !e.FirstCancelAt.Equal(t0) || e.Cause != cancellation.CauseClientGonePre || e.Model != "model-x" || e.StrayChunks != 1 {
		t.Fatalf("entry = %+v", e)
	}
	if _, ok := z.Terminal("req-t"); ok {
		t.Fatal("entry must be removed on terminal")
	}
	if _, ok := z.Terminal("never"); ok {
		t.Fatal("unknown id must not resolve")
	}
	if z.Len() != 0 {
		t.Fatalf("size = %d, want 0", z.Len())
	}
}

// TestZombieStreamCancellerRecordIsIdempotentAndForgetOnlyDropsCreated: a
// second record for the same id neither resets the schedule nor creates, and
// forget after a non-creating record leaves the original entry alone.
func TestZombieStreamCancellerRecordIsIdempotent(t *testing.T) {
	z := newZombieFixture()

	t0 := time.Now()
	z.Record("req-i", "m", cancellation.CauseOverflow, t0)
	z.MarkSent("req-i", t0)
	created, _ := z.Record("req-i", "m", cancellation.CauseHedgeLoser, t0.Add(time.Second))
	if created {
		t.Fatal("second record must not create")
	}
	e, ok := z.Terminal("req-i")
	if !ok || e.Cause != cancellation.CauseOverflow || !e.FirstCancelAt.Equal(t0) {
		t.Fatalf("entry = %+v, want original cause and first cancel time", e)
	}
	// forget drops the entry.
	z.Record("req-g", "m", cancellation.CauseOverflow, t0)
	z.Forget("req-g")
	if z.Len() != 0 {
		t.Fatal("forget must drop the entry")
	}
}

// TestZombieStreamCancellerSweepExpiresIdleEntries: an entry idle past
// zombieEntryTTL is returned as expired on the next touch, preserving its last
// stray-chunk time so the caller can report it as the terminal.
func TestZombieStreamCancellerSweepExpiresIdleEntries(t *testing.T) {
	z := newZombieFixture()

	t0 := time.Now()
	z.Record("req-a", "m", cancellation.CauseClientGonePost, t0)
	z.MarkSent("req-a", t0)
	deliverStrayChunk(z, "req-a", t0.Add(2*time.Second))
	z.Record("req-b", "m", cancellation.CauseHedgeLoser, t0) // never any chunk

	// Still live just under the TTL (activity = last stray chunk at +2 s).
	if _, expired := z.Record("other", "m", cancellation.CauseHedgeLoser, t0.Add(2*time.Second+cancellation.EntryTTL)); len(expired) != 1 {
		t.Fatalf("expected only req-b (idle since t0) expired, got %d", len(expired))
	}
	_, expired := z.Record("other2", "m", cancellation.CauseHedgeLoser, t0.Add(3*time.Second+cancellation.EntryTTL))
	if len(expired) != 1 {
		t.Fatalf("expected req-a expired, got %d", len(expired))
	}
	if e := expired[0]; e.Cause != cancellation.CauseClientGonePost || !e.LastStrayAt.Equal(t0.Add(2*time.Second)) {
		t.Fatalf("expired entry = %+v", e)
	}
	if _, ok := z.Terminal("req-a"); ok {
		t.Fatal("expired entry must be gone")
	}
}

// TestZombieStreamCancellerBounded: the map never exceeds its cap; the
// least recently active entry is evicted and reported.
func TestZombieStreamCancellerBounded(t *testing.T) {
	z := newZombieFixture()

	t0 := time.Now()
	evicted := 0
	for i := 0; i < cancellation.MaxEntries+100; i++ {
		_, expired := z.Record(fmt.Sprintf("req-%d", i), "m", cancellation.CauseHedgeLoser, t0.Add(time.Duration(i)*time.Millisecond))
		evicted += len(expired)
		if z.Len() > cancellation.MaxEntries {
			t.Fatalf("size %d exceeds cap", z.Len())
		}
	}
	if evicted != 100 {
		t.Fatalf("evicted = %d, want 100", evicted)
	}
	// The oldest ids were the ones evicted.
	if _, ok := z.Terminal("req-0"); ok {
		t.Fatal("req-0 should have been evicted first")
	}
	if _, ok := z.Terminal(fmt.Sprintf("req-%d", cancellation.MaxEntries+99)); !ok {
		t.Fatal("newest entry must survive")
	}
}

// TestStrayChunkWarnRateLimit: one Warn per provider per window, with the
// suppressed count carried onto the next allowed line; providers independent.
func TestStrayChunkWarnRateLimit(t *testing.T) {
	z := newZombieFixture()

	t0 := time.Now()
	if allow, n := z.AllowStrayWarn("p1", t0); !allow || n != 0 {
		t.Fatalf("first warn: allow=%v n=%d", allow, n)
	}
	for i := 1; i <= 5; i++ {
		if allow, n := z.AllowStrayWarn("p1", t0.Add(time.Duration(i)*time.Second)); allow || n != i {
			t.Fatalf("within window #%d: allow=%v n=%d", i, allow, n)
		}
	}
	if allow, n := z.AllowStrayWarn("p2", t0.Add(time.Second)); !allow || n != 0 {
		t.Fatalf("other provider: allow=%v n=%d", allow, n)
	}
	if allow, n := z.AllowStrayWarn("p1", t0.Add(cancellation.WarnEvery)); !allow || n != 5 {
		t.Fatalf("after window: allow=%v suppressed=%d, want allow with 5", allow, n)
	}
	if allow, n := z.AllowStrayWarn("p1", t0.Add(cancellation.WarnEvery+time.Second)); allow || n != 1 {
		t.Fatalf("counter must reset after an allowed line: allow=%v n=%d", allow, n)
	}
}

func TestCancelEnqueueIsAtomicWithTerminalResolution(t *testing.T) {
	z := newZombieFixture()

	z.Record("immediate-terminal", "m", cancellation.CauseClientGonePost, time.Now())
	enqueuing := make(chan struct{})
	finishEnqueue := make(chan struct{})
	sendDone := make(chan bool, 1)
	go func() {
		index, sent := z.Send("immediate-terminal", func() bool {
			close(enqueuing)
			<-finishEnqueue
			return true
		})
		sendDone <- sent && index == 0
	}()
	<-enqueuing
	terminalStarted := make(chan struct{})
	terminalDone := make(chan cancellation.Entry, 1)
	go func() {
		close(terminalStarted)
		e, _ := z.Terminal("immediate-terminal")
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
	if e.Sent != 1 || e.FirstSentAt.IsZero() {
		t.Fatalf("immediate terminal classified delivered enqueue as unsent: %+v", e)
	}
}

func TestCancelEvictedEntryStillReceivesBestEffortSend(t *testing.T) {
	z := newZombieFixture()

	z.Record("evicted", "m", cancellation.CauseClientGonePost, time.Now())
	z.Forget("evicted") // a bounded-map eviction before the abandon path resumes
	called := false
	index, sent := z.Send("evicted", func() bool {
		called = true
		return true
	})
	if !called || !sent || index != -1 {
		t.Fatalf("untracked best-effort send = (%d, %v), called=%v", index, sent, called)
	}
}
