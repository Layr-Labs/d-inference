package cancellation

import (
	"sync"
	"time"
)

const (
	MaxEntries = 4096
	// zombieEntryTTL bounds how long an entry waits for its terminal after its
	// last activity (cancel send or stray chunk). It exceeds the settlement
	// grace (defaultTerminalSettleGrace) so a post-commit terminal that still
	// settles billing is correlated, and covers a cold model load that delays
	// the provider's cancel handling by minutes.
	EntryTTL = 5 * time.Minute
	// zombieSweepEvery rate-limits the opportunistic full-map sweep.
	zombieSweepEvery = time.Second
	// zombieResendRetry is how soon a stray chunk may re-attempt a cancel whose
	// send failed (control lane full / writer stopped).
	ResendRetry = 250 * time.Millisecond
	// zombieResendInterval is the steady re-send cadence once the escalating
	// schedule is exhausted.
	zombieResendInterval = 30 * time.Second
	// zombieResendIndexMax caps the resend_index metric tag: 0 = the first
	// cancel was triggered by a stray chunk (no abandon path recorded one),
	// 1..3 = the escalating schedule, 4 = the steady zombieResendInterval regime.
	zombieResendIndexMax = 4
	// strayChunkWarnEvery rate-limits the "chunk for unknown request" Warn to
	// one line per provider per window; chunks suppressed in between are
	// counted on the next line.
	WarnEvery = 10 * time.Second
	// strayChunkWarnStateTTL drops a provider's rate-limit state once it has
	// been silent this long, keeping that map bounded by live providers.
	strayChunkWarnStateTTL = 10 * WarnEvery
)

// zombieResendSchedule holds the re-send instants relative to the FIRST
// cancel. Points already in the past when a re-send fires are skipped, so a
// zombie whose first stray chunk arrives late gets one re-send, not a burst.
var zombieResendSchedule = []time.Duration{time.Second, 3 * time.Second, 10 * time.Second}

// zombieEntry is one abandoned request awaiting its provider terminal.
type Entry struct {
	Model string
	Cause string
	// firstCancelAt anchors tracking expiry and the re-send schedule.
	FirstCancelAt time.Time
	// firstSentAt anchors latency only after the first successful enqueue.
	FirstSentAt time.Time
	LastSentAt  time.Time
	// lastStrayAt is the last chunk seen for the request after it was
	// abandoned (zero if none): the last evidence of generation.
	LastStrayAt  time.Time
	nextResendAt time.Time
	scheduleIdx  int
	// sent counts cancels actually handed to the provider writer so far: the
	// abandon path's first plus re-sends. It stays 0 while every enqueue has
	// failed (control lane full, writer stopped), so a terminal that arrives
	// then is the provider finishing on its own, not honoring a cancel.
	Sent        int
	StrayChunks int
}

func (e *Entry) lastActivity() time.Time {
	t := e.FirstCancelAt
	if e.LastSentAt.After(t) {
		t = e.LastSentAt
	}
	if e.LastStrayAt.After(t) {
		t = e.LastStrayAt
	}
	return t
}

// markSent records a cancel send at now, returning its resend index (0 for
// the very first send), and arms the next re-send instant.
func (e *Entry) MarkSent(now time.Time) (ResendIndex int) {
	ResendIndex = min(e.Sent, zombieResendIndexMax)
	if e.Sent == 0 {
		e.FirstSentAt = now
	}
	e.Sent++
	e.LastSentAt = now
	for e.scheduleIdx < len(zombieResendSchedule) {
		at := e.FirstCancelAt.Add(zombieResendSchedule[e.scheduleIdx])
		e.scheduleIdx++
		if at.After(now) {
			e.nextResendAt = at
			return ResendIndex
		}
	}
	e.nextResendAt = now.Add(zombieResendInterval)
	return ResendIndex
}

func (e *Entry) resendDue(now time.Time) bool {
	return !now.Before(e.nextResendAt)
}

// strayChunkWarnState rate-limits the unknown-chunk Warn for one provider.
type strayChunkWarnState struct {
	lastWarnAt time.Time
	suppressed int
}

// zombieStreamCanceller is the per-request map behind the tracking above.
// All methods are nil-receiver safe: a Server built without one (zero-value
// literals in tests) cancels stray chunks but tracks nothing.
type Tracker struct {
	mu        sync.Mutex
	entries   *Index
	warn      map[string]*strayChunkWarnState
	lastSweep time.Time
}

func NewTracker(entries *Index) *Tracker {
	if entries == nil {
		entries = &Index{}
	}
	return &Tracker{
		entries: entries,
		warn:    make(map[string]*strayChunkWarnState),
	}
}

// strayChunkResult is what strayChunk decided for one chunk.
type Decision struct {
	// send reports whether a cancel should be (re-)sent now; resendIndex is
	// the index that send would carry (0 = no cancel delivered yet).
	Send        bool
	ResendIndex int
	// cause is the entry's cancel cause; cancelCauseStrayChunk means no abandon
	// path ever recorded this id — it is genuinely unknown.
	Cause   string
	Model   string
	Expired []Entry
}

// ensureMapsLocked makes a canceller literal (nil maps) usable. Caller holds mu.
func (z *Tracker) ensureMapsLocked() {
	if z.entries == nil {
		z.entries = &Index{}
	}
	if z.warn == nil {
		z.warn = make(map[string]*strayChunkWarnState)
	}
}

// record registers an abandon-path cancel for requestID before it is sent.
// Idempotent: an existing entry is left untouched. created reports whether
// this call inserted the entry (so a caller that then decides not to cancel
// can forget only what it created).
func (z *Tracker) Record(requestID, Model, Cause string, now time.Time) (created bool, Expired []Entry) {
	if z == nil {
		return false, nil
	}
	z.mu.Lock()
	z.ensureMapsLocked()
	defer z.mu.Unlock()
	Expired = z.sweepLocked(now)
	if z.entries.Lookup(requestID) != nil {
		return false, Expired
	}
	Expired = append(Expired, z.makeRoomLocked()...)
	z.entries.Insert(requestID, &Entry{Model: Model, Cause: Cause, FirstCancelAt: now})
	return true, Expired
}

// markSent notes that a cancel was just handed to the provider writer for a
// recorded requestID and returns its resend index (0 for the first cancel
// delivered for the id, whichever path delivered it; -1 for an untracked id).
// Callers invoke it only after the enqueue succeeded.
func (z *Tracker) MarkSent(requestID string, now time.Time) (ResendIndex int) {
	if z == nil {
		return -1
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	e := z.entries.Lookup(requestID)
	if e == nil {
		return -1
	}
	z.entries.Touch(requestID)
	return e.MarkSent(now)
}

// send atomically records a successful enqueue before a terminal or sweep can
// remove its entry. enqueue must only submit to the nonblocking provider control
// queue; it must not wait for the frame to reach the network. Provider terminals
// may arrive as soon as enqueue succeeds, so releasing mu between enqueue and
// markSent would misclassify a delivered cancel as unsent.
func (z *Tracker) Send(requestID string, enqueue func() bool) (ResendIndex int, Sent bool) {
	if z == nil {
		return -1, enqueue()
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	e := z.entries.Lookup(requestID)
	if e == nil {
		// The bounded tracker may have evicted the entry while the abandon
		// path released capacity. Preserve its best-effort cancel even when
		// terminal correlation is no longer available.
		return -1, enqueue()
	}
	if !enqueue() {
		e.nextResendAt = time.Now().Add(ResendRetry)
		return -1, false
	}
	z.entries.Touch(requestID)
	return e.MarkSent(time.Now()), true
}

// forget drops requestID: a terminal had already claimed the attempt, so no
// cancel was sent and there is nothing to correlate.
func (z *Tracker) Forget(requestID string) {
	if z == nil {
		return
	}
	z.mu.Lock()
	z.entries.Remove(requestID)
	z.mu.Unlock()
}

// noteSendFailed lets the next stray chunk re-attempt the cancel almost
// immediately instead of waiting for the schedule.
func (z *Tracker) NoteSendFailed(requestID string, now time.Time) {
	if z == nil {
		return
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	if e := z.entries.Lookup(requestID); e != nil {
		e.nextResendAt = now.Add(ResendRetry)
	}
}

// strayChunk notes a chunk for a request the coordinator no longer tracks and
// decides whether to (re-)send the cancel. An id nobody abandoned gets an
// entry of its own (cause cancelCauseStrayChunk) and an immediate cancel. A
// send decision holds the entry for zombieResendRetry so a burst of chunks
// yields one attempt; the caller marks the send (markSent) only after the
// enqueue succeeded, or leaves the hold as the retry point when it failed.
func (z *Tracker) StrayChunk(requestID string, now time.Time) Decision {
	if z == nil {
		// Untracked (zero-value Server): still cancel, never throttle.
		return Decision{Send: true, Cause: CauseStrayChunk}
	}
	z.mu.Lock()
	z.ensureMapsLocked()
	defer z.mu.Unlock()
	res := Decision{Expired: z.sweepLocked(now)}
	e := z.entries.Lookup(requestID)
	if e == nil {
		res.Expired = append(res.Expired, z.makeRoomLocked()...)
		e = &Entry{Cause: CauseStrayChunk, FirstCancelAt: now}
		z.entries.Insert(requestID, e)
	}
	e.StrayChunks++
	e.LastStrayAt = now
	z.entries.Touch(requestID)
	res.Cause = e.Cause
	res.Model = e.Model
	if e.resendDue(now) {
		res.Send = true
		res.ResendIndex = min(e.Sent, zombieResendIndexMax)
		e.nextResendAt = now.Add(ResendRetry)
	}
	return res
}

// terminal resolves requestID against a provider terminal: it returns and
// removes the entry, or reports false when the id was never abandoned.
func (z *Tracker) Terminal(requestID string) (Entry, bool) {
	if z == nil {
		return Entry{}, false
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	e := z.entries.Lookup(requestID)
	if e == nil {
		return Entry{}, false
	}
	z.entries.Remove(requestID)
	return *e, true
}

// allowStrayWarn reports whether the unknown-chunk Warn may be logged for
// providerID now, with the number of chunks suppressed since the last line.
func (z *Tracker) AllowStrayWarn(providerID string, now time.Time) (allow bool, suppressed int) {
	if z == nil {
		return true, 0
	}
	z.mu.Lock()
	z.ensureMapsLocked()
	defer z.mu.Unlock()
	st := z.warn[providerID]
	if st == nil {
		z.warn[providerID] = &strayChunkWarnState{lastWarnAt: now}
		return true, 0
	}
	if now.Sub(st.lastWarnAt) < WarnEvery {
		st.suppressed++
		return false, st.suppressed
	}
	suppressed = st.suppressed
	st.suppressed = 0
	st.lastWarnAt = now
	return true, suppressed
}

// size reports the number of tracked requests.
func (z *Tracker) Len() int {
	if z == nil {
		return 0
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	return z.entries.Len()
}

// sweepLocked expires entries idle past zombieEntryTTL (and stale warn state),
// at most once per zombieSweepEvery. Expired entries are
// returned so the caller can report them outside the lock.
func (z *Tracker) sweepLocked(now time.Time) []Entry {
	if now.Sub(z.lastSweep) < zombieSweepEvery {
		return nil
	}
	z.lastSweep = now
	var Expired []Entry
	for id := range z.entries.items {
		e := z.entries.Lookup(id)
		if now.Sub(e.lastActivity()) > EntryTTL {
			Expired = append(Expired, *e)
			z.entries.Remove(id)
		}
	}
	for id, st := range z.warn {
		if now.Sub(st.lastWarnAt) > strayChunkWarnStateTTL {
			delete(z.warn, id)
		}
	}
	return Expired
}
