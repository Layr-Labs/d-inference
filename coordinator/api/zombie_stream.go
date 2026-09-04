package api

import (
	"sync"
	"time"
)

// Zombie-stream cancel tracking.
//
// Every abandon path that may leave a provider generating records its request
// here before it sends the cancel (sendAbandonCancel / cancelDispatch) and
// marks the entry sent only once the frame was handed to the provider writer.
// The entry lets the coordinator:
//
//   - correlate the provider's eventual terminal with the cancel and emit
//     inference.cancel_to_terminal_ms instead of dropping it as "unknown";
//   - re-send the cancel on an escalating schedule while stray chunks prove the
//     provider has not stopped, so a cancel lost to a full control lane or
//     delayed behind a cold model load is retried within ~1 s, not 10 s;
//   - attribute every cancel to a bounded cause.
//
// The map is bounded (zombieCancelMaxEntries) and swept opportunistically by
// the calls that touch it — there is no background goroutine, so a
// terminal-less entry is reported when the map is next used, not exactly at
// expiry.

const (
	zombieCancelMaxEntries = 4096
	// zombieEntryTTL bounds how long an entry waits for its terminal after its
	// last activity (cancel send or stray chunk). It exceeds the settlement
	// grace (defaultTerminalSettleGrace) so a post-commit terminal that still
	// settles billing is correlated, and covers a cold model load that delays
	// the provider's cancel handling by minutes.
	zombieEntryTTL = 5 * time.Minute
	// zombieSweepEvery rate-limits the opportunistic full-map sweep.
	zombieSweepEvery = time.Second
	// zombieResendRetry is how soon a stray chunk may re-attempt a cancel whose
	// send failed (control lane full / writer stopped).
	zombieResendRetry = 250 * time.Millisecond
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
	strayChunkWarnEvery = 10 * time.Second
	// strayChunkWarnStateTTL drops a provider's rate-limit state once it has
	// been silent this long, keeping that map bounded by live providers.
	strayChunkWarnStateTTL = 10 * strayChunkWarnEvery
)

// zombieResendSchedule holds the re-send instants relative to the FIRST
// cancel. Points already in the past when a re-send fires are skipped, so a
// zombie whose first stray chunk arrives late gets one re-send, not a burst.
var zombieResendSchedule = []time.Duration{time.Second, 3 * time.Second, 10 * time.Second}

// zombieEntry is one abandoned request awaiting its provider terminal.
type zombieEntry struct {
	model string
	cause string
	// firstCancelAt anchors tracking expiry and the re-send schedule.
	firstCancelAt time.Time
	// firstSentAt anchors latency only after the first successful enqueue.
	firstSentAt time.Time
	lastSentAt  time.Time
	// lastStrayAt is the last chunk seen for the request after it was
	// abandoned (zero if none): the last evidence of generation.
	lastStrayAt  time.Time
	nextResendAt time.Time
	scheduleIdx  int
	// sent counts cancels actually handed to the provider writer so far: the
	// abandon path's first plus re-sends. It stays 0 while every enqueue has
	// failed (control lane full, writer stopped), so a terminal that arrives
	// then is the provider finishing on its own, not honoring a cancel.
	sent        int
	strayChunks int
}

func (e *zombieEntry) lastActivity() time.Time {
	t := e.firstCancelAt
	if e.lastSentAt.After(t) {
		t = e.lastSentAt
	}
	if e.lastStrayAt.After(t) {
		t = e.lastStrayAt
	}
	return t
}

// markSent records a cancel send at now, returning its resend index (0 for
// the very first send), and arms the next re-send instant.
func (e *zombieEntry) markSent(now time.Time) (resendIndex int) {
	resendIndex = min(e.sent, zombieResendIndexMax)
	if e.sent == 0 {
		e.firstSentAt = now
	}
	e.sent++
	e.lastSentAt = now
	for e.scheduleIdx < len(zombieResendSchedule) {
		at := e.firstCancelAt.Add(zombieResendSchedule[e.scheduleIdx])
		e.scheduleIdx++
		if at.After(now) {
			e.nextResendAt = at
			return resendIndex
		}
	}
	e.nextResendAt = now.Add(zombieResendInterval)
	return resendIndex
}

func (e *zombieEntry) resendDue(now time.Time) bool {
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
type zombieStreamCanceller struct {
	mu        sync.Mutex
	entries   map[string]*zombieEntry
	warn      map[string]*strayChunkWarnState
	lastSweep time.Time
}

func newZombieStreamCanceller() *zombieStreamCanceller {
	return &zombieStreamCanceller{
		entries: make(map[string]*zombieEntry),
		warn:    make(map[string]*strayChunkWarnState),
	}
}

// strayChunkResult is what strayChunk decided for one chunk.
type strayChunkResult struct {
	// send reports whether a cancel should be (re-)sent now; resendIndex is
	// the index that send would carry (0 = no cancel delivered yet).
	send        bool
	resendIndex int
	// cause is the entry's cancel cause; cancelCauseStrayChunk means no abandon
	// path ever recorded this id — it is genuinely unknown.
	cause   string
	model   string
	expired []zombieEntry
}

// ensureMapsLocked makes a canceller literal (nil maps) usable. Caller holds mu.
func (z *zombieStreamCanceller) ensureMapsLocked() {
	if z.entries == nil {
		z.entries = make(map[string]*zombieEntry)
	}
	if z.warn == nil {
		z.warn = make(map[string]*strayChunkWarnState)
	}
}

// record registers an abandon-path cancel for requestID before it is sent.
// Idempotent: an existing entry is left untouched. created reports whether
// this call inserted the entry (so a caller that then decides not to cancel
// can forget only what it created).
func (z *zombieStreamCanceller) record(requestID, model, cause string, now time.Time) (created bool, expired []zombieEntry) {
	if z == nil {
		return false, nil
	}
	z.mu.Lock()
	z.ensureMapsLocked()
	defer z.mu.Unlock()
	expired = z.sweepLocked(now, false)
	if _, ok := z.entries[requestID]; ok {
		return false, expired
	}
	expired = append(expired, z.makeRoomLocked(now)...)
	z.entries[requestID] = &zombieEntry{model: model, cause: cause, firstCancelAt: now}
	return true, expired
}

// markSent notes that a cancel was just handed to the provider writer for a
// recorded requestID and returns its resend index (0 for the first cancel
// delivered for the id, whichever path delivered it; -1 for an untracked id).
// Callers invoke it only after the enqueue succeeded.
func (z *zombieStreamCanceller) markSent(requestID string, now time.Time) (resendIndex int) {
	if z == nil {
		return -1
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	e := z.entries[requestID]
	if e == nil {
		return -1
	}
	return e.markSent(now)
}

// send atomically records a successful enqueue before a terminal or sweep can
// remove its entry. enqueue must only submit to the nonblocking provider control
// queue; it must not wait for the frame to reach the network. Provider terminals
// may arrive as soon as enqueue succeeds, so releasing mu between enqueue and
// markSent would misclassify a delivered cancel as unsent.
func (z *zombieStreamCanceller) send(requestID string, enqueue func() bool) (resendIndex int, sent bool) {
	if z == nil {
		return -1, enqueue()
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	e := z.entries[requestID]
	if e == nil {
		// The bounded tracker may have evicted the entry while the abandon
		// path released capacity. Preserve its best-effort cancel even when
		// terminal correlation is no longer available.
		return -1, enqueue()
	}
	if !enqueue() {
		e.nextResendAt = time.Now().Add(zombieResendRetry)
		return -1, false
	}
	return e.markSent(time.Now()), true
}

// forget drops requestID: a terminal had already claimed the attempt, so no
// cancel was sent and there is nothing to correlate.
func (z *zombieStreamCanceller) forget(requestID string) {
	if z == nil {
		return
	}
	z.mu.Lock()
	delete(z.entries, requestID)
	z.mu.Unlock()
}

// noteSendFailed lets the next stray chunk re-attempt the cancel almost
// immediately instead of waiting for the schedule.
func (z *zombieStreamCanceller) noteSendFailed(requestID string, now time.Time) {
	if z == nil {
		return
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	if e := z.entries[requestID]; e != nil {
		e.nextResendAt = now.Add(zombieResendRetry)
	}
}

// strayChunk notes a chunk for a request the coordinator no longer tracks and
// decides whether to (re-)send the cancel. An id nobody abandoned gets an
// entry of its own (cause cancelCauseStrayChunk) and an immediate cancel. A
// send decision holds the entry for zombieResendRetry so a burst of chunks
// yields one attempt; the caller marks the send (markSent) only after the
// enqueue succeeded, or leaves the hold as the retry point when it failed.
func (z *zombieStreamCanceller) strayChunk(requestID string, now time.Time) strayChunkResult {
	if z == nil {
		// Untracked (zero-value Server): still cancel, never throttle.
		return strayChunkResult{send: true, cause: cancelCauseStrayChunk}
	}
	z.mu.Lock()
	z.ensureMapsLocked()
	defer z.mu.Unlock()
	res := strayChunkResult{expired: z.sweepLocked(now, false)}
	e := z.entries[requestID]
	if e == nil {
		res.expired = append(res.expired, z.makeRoomLocked(now)...)
		e = &zombieEntry{cause: cancelCauseStrayChunk, firstCancelAt: now}
		z.entries[requestID] = e
	}
	e.strayChunks++
	e.lastStrayAt = now
	res.cause = e.cause
	res.model = e.model
	if e.resendDue(now) {
		res.send = true
		res.resendIndex = min(e.sent, zombieResendIndexMax)
		e.nextResendAt = now.Add(zombieResendRetry)
	}
	return res
}

// terminal resolves requestID against a provider terminal: it returns and
// removes the entry, or reports false when the id was never abandoned.
func (z *zombieStreamCanceller) terminal(requestID string) (zombieEntry, bool) {
	if z == nil {
		return zombieEntry{}, false
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	e, ok := z.entries[requestID]
	if !ok {
		return zombieEntry{}, false
	}
	delete(z.entries, requestID)
	return *e, true
}

// allowStrayWarn reports whether the unknown-chunk Warn may be logged for
// providerID now, with the number of chunks suppressed since the last line.
func (z *zombieStreamCanceller) allowStrayWarn(providerID string, now time.Time) (allow bool, suppressed int) {
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
	if now.Sub(st.lastWarnAt) < strayChunkWarnEvery {
		st.suppressed++
		return false, st.suppressed
	}
	suppressed = st.suppressed
	st.suppressed = 0
	st.lastWarnAt = now
	return true, suppressed
}

// size reports the number of tracked requests (tests).
func (z *zombieStreamCanceller) size() int {
	if z == nil {
		return 0
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	return len(z.entries)
}

// sweepLocked expires entries idle past zombieEntryTTL (and stale warn state),
// at most once per zombieSweepEvery unless forced. Expired entries are
// returned so the caller can report them outside the lock.
func (z *zombieStreamCanceller) sweepLocked(now time.Time, force bool) []zombieEntry {
	if !force && now.Sub(z.lastSweep) < zombieSweepEvery {
		return nil
	}
	z.lastSweep = now
	var expired []zombieEntry
	for id, e := range z.entries {
		if now.Sub(e.lastActivity()) > zombieEntryTTL {
			expired = append(expired, *e)
			delete(z.entries, id)
		}
	}
	for id, st := range z.warn {
		if now.Sub(st.lastWarnAt) > strayChunkWarnStateTTL {
			delete(z.warn, id)
		}
	}
	return expired
}

// makeRoomLocked keeps the map under its cap ahead of an insert: expire first,
// then evict the least recently active entry.
func (z *zombieStreamCanceller) makeRoomLocked(now time.Time) []zombieEntry {
	if len(z.entries) < zombieCancelMaxEntries {
		return nil
	}
	expired := z.sweepLocked(now, true)
	if len(z.entries) < zombieCancelMaxEntries {
		return expired
	}
	var oldestID string
	var oldest time.Time
	for id, e := range z.entries {
		if la := e.lastActivity(); oldestID == "" || la.Before(oldest) {
			oldestID, oldest = id, la
		}
	}
	if oldestID != "" {
		expired = append(expired, *z.entries[oldestID])
		delete(z.entries, oldestID)
	}
	return expired
}
