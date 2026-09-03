package registry

// Per-request profiling record (system profiler, slice 1).
//
// A RequestProfile is created once per inference HTTP request at handler
// entry and shared by every dispatch attempt of that request. It carries
// prompt-free timing offsets (microseconds from the coordinator's monotonic
// t0), bounded counters, and the routing decision context copied BY VALUE
// from RoutingDecision after the registry lock is released.
//
// Concurrency contract:
//   - Offsets and counters are atomic.Int64 so the dispatch goroutine, the
//     provider WS read loop, and the settlement timer can stamp without a lock.
//   - A stamp is first-write-wins (Stamp only stores when the field is 0), so a
//     retried attempt or a racing late terminal can never overwrite an earlier
//     observation. 0 means "not observed"; an observation that lands at exactly
//     0 µs is stored as 1 so it stays distinguishable from unset.
//   - Small string/struct fields written once by the request owner before the
//     record is shared are plain fields; anything written by the read loop is
//     guarded by mu.
//   - Each AttemptProfile finalizes exactly once when BOTH halves are done: the
//     handler half (dispatch loop finished with the attempt) and the terminal
//     half (provider terminal, synthetic terminal, or grace expiry). Whichever
//     half completes second runs the finalize callback. A fallback timer armed at
//     the handler half guarantees finalization even when no terminal ever
//     arrives.
//
// Nothing in this file touches the hot path beyond one clock read + one atomic
// store per stamp. It never blocks, allocates per token, or takes r.mu.

import (
	"sync"
	"sync/atomic"
	"time"
)

// profileAttemptInline is the number of attempts stored inline before spilling
// to the overflow slice (retries + one speculative backup cover the common case).
const profileAttemptInline = 2

// RequestProfile is the request-level profile shared across attempts.
type RequestProfile struct {
	T0             time.Time
	CoordRequestID string
	Endpoint       string // mux pattern
	Stream         bool
	Model          string
	PublicModel    string

	// Pre-handler stamps copied from the middleware meta at creation.
	AuthDoneUS      int64
	RatelimitDoneUS int64
	SealedOpenUS    int64
	AuthKind        string
	AuthDBRead      bool

	// Request-level offsets (µs from T0).
	HandlerEntryUS   atomic.Int64
	ParsedUS         atomic.Int64
	ReservedUS       atomic.Int64
	MediaFetchedUS   atomic.Int64
	PreflightDoneUS  atomic.Int64
	PlanDoneUS       atomic.Int64
	HeadersWrittenUS atomic.Int64
	FirstFlushUS     atomic.Int64
	LastFlushUS      atomic.Int64
	ClientGoneUS     atomic.Int64
	DoneFlushedUS    atomic.Int64

	// Accumulators.
	DBUS    atomic.Int64 // synchronous store calls on the handler goroutine (µs)
	DBCalls atomic.Int64
	// ChunksOut counts SSE frames (client-visible events) written — one per
	// frame, never per Write or Flush, so the coalesced chat relay (a batch of
	// frames per write) and the per-frame emitters agree. BytesOut is the
	// bytes the ResponseWriter accepted; MaxChunkGapUS is the longest gap
	// between successive client writes (frames inside one batch have none).
	ChunksOut      atomic.Int64
	BytesOut       atomic.Int64
	MaxChunkGapUS  atomic.Int64
	ClientWriteErr atomic.Bool

	// Written once by the handler goroutine.
	BodyBytes            int
	SealedBodyBytes      int
	ReserveMode          string
	MediaItems           int
	MediaBytes           int64
	PreflightOutcome     string
	PreflightUS          int64
	PlanOutcome          string
	FirstContentBudgetMs int
	AdmissionMode        string
	// Request shape (bounded numbers/bools; never content).
	EstimatedPromptTokens int
	RequestedMaxTokens    int
	RequiresVision        bool
	HasTools              bool

	// Late-written request-level fields: an earlier attempt may already be
	// flattening on the sink worker when the handler writes these, so they are
	// guarded rather than plain.
	lateMu             sync.Mutex
	heldPreambleChunks int
	clientGonePhase    string

	finalize      ProfileFinalizeFn
	fallbackGrace time.Duration

	attemptsMu sync.Mutex
	inline     [profileAttemptInline]AttemptProfile
	overflow   []*AttemptProfile
	count      int
}

// NewRequestProfile creates a profile anchored at t0. finalize may be nil (the
// record is then dropped at finalization, which keeps the kill switch trivial).
// fallbackGrace bounds how long an attempt may wait for its terminal half after
// the handler half completed before it is finalized without a terminal.
func NewRequestProfile(t0 time.Time, coordRequestID string, finalize ProfileFinalizeFn, fallbackGrace time.Duration) *RequestProfile {
	if t0.IsZero() {
		t0 = time.Now()
	}
	return &RequestProfile{
		T0:             t0,
		CoordRequestID: coordRequestID,
		finalize:       finalize,
		fallbackGrace:  fallbackGrace,
	}
}

// offsetUS returns the microseconds elapsed since T0, never less than 1 so a
// stored stamp is always distinguishable from the 0 "unset" sentinel.
func (rp *RequestProfile) offsetUS() int64 {
	if rp == nil {
		return 0
	}
	us := time.Since(rp.T0).Microseconds()
	if us < 1 {
		us = 1
	}
	return us
}

// Stamp records now (µs from T0) into f if f is still unset. Safe to call from
// any goroutine; nil-receiver safe so call sites need no guards.
func (rp *RequestProfile) Stamp(f *atomic.Int64) {
	if rp == nil || f == nil {
		return
	}
	f.CompareAndSwap(0, rp.offsetUS())
}

// StampAt records t (converted to µs from T0) into f if f is still unset. Used
// where an ingress timestamp was captured earlier than the stamping call.
func (rp *RequestProfile) StampAt(f *atomic.Int64, t time.Time) {
	if rp == nil || f == nil || t.IsZero() {
		return
	}
	us := t.Sub(rp.T0).Microseconds()
	if us < 1 {
		us = 1
	}
	f.CompareAndSwap(0, us)
}

// AddDuration accumulates a duration (µs) into an accumulator field.
func (rp *RequestProfile) AddDuration(f *atomic.Int64, d time.Duration) {
	if rp == nil || f == nil || d <= 0 {
		return
	}
	f.Add(d.Microseconds())
}

// NewAttempt allocates (inline when possible) and registers the next attempt.
func (rp *RequestProfile) NewAttempt(requestID string, attempt int, backupOf string) *AttemptProfile {
	if rp == nil {
		return nil
	}
	rp.attemptsMu.Lock()
	defer rp.attemptsMu.Unlock()
	var ap *AttemptProfile
	if rp.count < profileAttemptInline {
		ap = &rp.inline[rp.count]
	} else {
		ap = &AttemptProfile{}
		rp.overflow = append(rp.overflow, ap)
	}
	ap.RequestID = requestID
	ap.Attempt = attempt
	ap.BackupOf = backupOf
	ap.Index = rp.count
	ap.parent = rp
	rp.count++
	return ap
}

// AttemptCount returns the number of attempts registered so far.
func (rp *RequestProfile) AttemptCount() int {
	if rp == nil {
		return 0
	}
	rp.attemptsMu.Lock()
	defer rp.attemptsMu.Unlock()
	return rp.count
}

// Attempts returns a snapshot slice of the registered attempts (pointers).
func (rp *RequestProfile) Attempts() []*AttemptProfile {
	if rp == nil {
		return nil
	}
	rp.attemptsMu.Lock()
	defer rp.attemptsMu.Unlock()
	out := make([]*AttemptProfile, 0, rp.count)
	for i := 0; i < rp.count && i < profileAttemptInline; i++ {
		out = append(out, &rp.inline[i])
	}
	out = append(out, rp.overflow...)
	return out
}

// OffsetNowUS returns the current offset from T0 in microseconds (≥ 1).
func (rp *RequestProfile) OffsetNowUS() int64 { return rp.offsetUS() }

// DispatchedAttempts counts attempts whose frame reached the provider writer.
// Reserve failures and queue placeholders are not counted, so a queued request
// that dispatched once reports 1.
func (rp *RequestProfile) DispatchedAttempts() int {
	n := 0
	for _, ap := range rp.Attempts() {
		if ap.Dispatched() {
			n++
		}
	}
	return n
}

// FailedAttempts returns the number of non-winning DISPATCHED attempts and the
// total microseconds they consumed (attempt start → next attempt start or
// completion ingress), best-effort from the stamps that exist.
func (rp *RequestProfile) FailedAttempts() (n int, totalUS int64) {
	if rp == nil {
		return 0, 0
	}
	attempts := rp.Attempts()
	for i, ap := range attempts {
		if ap.Winning.Load() || !ap.Dispatched() {
			continue
		}
		n++
		start := ap.AttemptStartUS.Load()
		if start == 0 {
			continue
		}
		end := int64(0)
		if i+1 < len(attempts) {
			end = attempts[i+1].AttemptStartUS.Load()
		}
		if end == 0 {
			end = ap.CompleteIngressUS.Load()
		}
		if end > start {
			totalUS += end - start
		}
	}
	return n, totalUS
}

// LastAttempt returns the most recently registered attempt (nil when none).
func (rp *RequestProfile) LastAttempt() *AttemptProfile {
	if rp == nil {
		return nil
	}
	rp.attemptsMu.Lock()
	defer rp.attemptsMu.Unlock()
	if rp.count == 0 {
		return nil
	}
	if rp.count <= profileAttemptInline {
		return &rp.inline[rp.count-1]
	}
	return rp.overflow[len(rp.overflow)-1]
}

// RequestStamp names a request-level stamp for the nil-safe Mark helper.
type RequestStamp uint8

const (
	StampReqHandlerEntry RequestStamp = iota
	StampReqParsed
	StampReqReserved
	StampReqMediaFetched
	StampReqPreflightDone
	StampReqPlanDone
	StampReqHeadersWritten
	StampReqFirstFlush
	StampReqLastFlush
	StampReqClientGone
	StampReqDoneFlushed
)

func (rp *RequestProfile) reqField(s RequestStamp) *atomic.Int64 {
	switch s {
	case StampReqHandlerEntry:
		return &rp.HandlerEntryUS
	case StampReqParsed:
		return &rp.ParsedUS
	case StampReqReserved:
		return &rp.ReservedUS
	case StampReqMediaFetched:
		return &rp.MediaFetchedUS
	case StampReqPreflightDone:
		return &rp.PreflightDoneUS
	case StampReqPlanDone:
		return &rp.PlanDoneUS
	case StampReqHeadersWritten:
		return &rp.HeadersWrittenUS
	case StampReqFirstFlush:
		return &rp.FirstFlushUS
	case StampReqLastFlush:
		return &rp.LastFlushUS
	case StampReqClientGone:
		return &rp.ClientGoneUS
	case StampReqDoneFlushed:
		return &rp.DoneFlushedUS
	}
	return nil
}

// Mark stamps now into the named request-level field. Nil-safe: call sites
// must never take the address of a field on a possibly-nil profile.
func (rp *RequestProfile) Mark(s RequestStamp) {
	if rp == nil {
		return
	}
	rp.Stamp(rp.reqField(s))
}

// SetClientGonePhase records the phase of a client disconnect (first write wins).
func (rp *RequestProfile) SetClientGonePhase(phase string) {
	if rp == nil || phase == "" {
		return
	}
	rp.lateMu.Lock()
	if rp.clientGonePhase == "" {
		rp.clientGonePhase = phase
	}
	rp.lateMu.Unlock()
}

// ClientGonePhase returns the recorded client-disconnect phase ("" if none).
func (rp *RequestProfile) ClientGonePhase() string {
	if rp == nil {
		return ""
	}
	rp.lateMu.Lock()
	defer rp.lateMu.Unlock()
	return rp.clientGonePhase
}

// SetHeldPreambleChunks records how many role-only chunks were held before
// the first content chunk committed.
func (rp *RequestProfile) SetHeldPreambleChunks(n int) {
	if rp == nil {
		return
	}
	rp.lateMu.Lock()
	rp.heldPreambleChunks = n
	rp.lateMu.Unlock()
}

// HeldPreambleChunks returns the held-preamble count.
func (rp *RequestProfile) HeldPreambleChunks() int {
	if rp == nil {
		return 0
	}
	rp.lateMu.Lock()
	defer rp.lateMu.Unlock()
	return rp.heldPreambleChunks
}
