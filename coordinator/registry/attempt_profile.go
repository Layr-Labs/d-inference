package registry

// AttemptProfile: the per-dispatch-attempt slice of the request profile —
// stamps (AttemptStamp), routing decision context, provider profile bytes,
// terminal usage and outcome. Lifecycle (two-halves finalize) lives in
// attempt_profile_finalize.go; the shared request-level record in
// request_profile.go.

import (
	"sync"
	"sync/atomic"
	"time"
)

// AttemptProfile holds the per-dispatch-attempt slice of the profile.
type AttemptProfile struct {
	GeneratedContentObserved atomic.Bool
	ProviderCompleteObserved atomic.Bool // matched complete received; independent of terminal arbitration
	// Identity (written once by the dispatch goroutine before sharing).
	RequestID  string // attempt UUID (joins inference_routes.request_id)
	Attempt    int
	BackupOf   string // primary attempt UUID when this is a speculative backup
	ProviderID string
	Index      int // position in the parent's attempt list
	// Provider snapshot copied (by value) at reserve time; folded by the api
	// layer before persistence (never persisted verbatim).
	ProviderVersion string
	ChipFamily      string
	KVBackend       string

	// Offsets (µs from RequestProfile.T0, first-write-wins, 0 = unset).
	AttemptStartUS        atomic.Int64
	ReserveLockAcquiredUS atomic.Int64
	ReserveDoneUS         atomic.Int64
	QueuedUS              atomic.Int64
	DequeuedUS            atomic.Int64
	TopupDoneUS           atomic.Int64
	EncryptedUS           atomic.Int64
	WriteSubmittedUS      atomic.Int64
	WriteDequeuedUS       atomic.Int64
	WriteDoneUS           atomic.Int64
	AcceptedUS            atomic.Int64
	FirstChunkIngressUS   atomic.Int64
	FirstChunkDequeuedUS  atomic.Int64
	FirstContentIngressUS atomic.Int64
	FirstContentUS        atomic.Int64
	CancelSentUS          atomic.Int64
	CompleteIngressUS     atomic.Int64
	SettleDBUS            atomic.Int64 // duration, accumulated
	FinalizedUS           atomic.Int64 // stamped when both halves completed (not when the row is built)

	// Counters (atomic; the WS read loop increments these per chunk).
	ChunksIn       atomic.Int64
	DecryptUSTotal atomic.Int64

	// Flags.
	Winning        atomic.Bool
	BackupLaunched atomic.Bool
	BackupWon      atomic.Bool

	// Decision context, copied by value on the dispatch goroutine AFTER
	// ReserveProviderEx returned (never under r.mu).
	Decision    RoutingDecision
	DecisionSet bool

	// mu guards everything below (written by the read loop / settlement path).
	mu                  sync.Mutex
	finalStatus         string
	errorReason         string
	terminalCause       string
	providerOutcome     string
	clientOutcome       string
	providerProfileRaw  []byte // bounded (≤ maxProviderProfileBytes) raw wire object; decoded off the hot path
	providerProfileLate bool   // a profile arrived after finalize
	providerProfileStat ProviderProfileStatus
	terminalRecorded    bool
	terminalClaimed     bool
	handlerDone         bool
	terminalPrompt      int
	terminalCompletion  int
	terminalUsageSet    bool

	parts    atomic.Int32
	once     sync.Once
	fallback *time.Timer
	parent   *RequestProfile
}

// Parent returns the owning request profile (nil-safe).
func (ap *AttemptProfile) Parent() *RequestProfile {
	if ap == nil {
		return nil
	}
	return ap.parent
}

// SetDecision copies the routing decision by value. Call on the dispatch
// goroutine after ReserveProviderEx has returned (never under r.mu).
func (ap *AttemptProfile) SetDecision(d RoutingDecision) {
	if ap == nil {
		return
	}
	ap.Decision = d
	ap.DecisionSet = true
	if ap.ProviderID == "" {
		ap.ProviderID = d.ProviderID
	}
	// The lock was acquired ScanUS+AdmitUS before ReserveProviderEx returned;
	// anchoring on the reserve-done stamp (not the attempt start) stays correct
	// for queued attempts whose reserve runs long after the attempt started.
	if done := ap.ReserveDoneUS.Load(); done > 0 {
		if acq := done - d.ScanUS - d.AdmitUS; acq > 0 {
			ap.ReserveLockAcquiredUS.CompareAndSwap(0, acq)
		}
	}
}

// CopyPreDispatchFrom copies the pre-dispatch stamps of another attempt into
// this one (used when a speculative backup wins, or on retries, so the winning
// row still shows how long routing/queueing took before its own dispatch).
func (ap *AttemptProfile) CopyPreDispatchFrom(src *AttemptProfile) {
	if ap == nil || src == nil || ap == src {
		return
	}
	copyIfUnset := func(dst, from *atomic.Int64) {
		if v := from.Load(); v != 0 {
			dst.CompareAndSwap(0, v)
		}
	}
	copyIfUnset(&ap.AttemptStartUS, &src.AttemptStartUS)
	copyIfUnset(&ap.QueuedUS, &src.QueuedUS)
	copyIfUnset(&ap.DequeuedUS, &src.DequeuedUS)
}

// maxProviderProfileBytes caps the raw provider profile object retained per
// attempt. Anything larger is dropped at ingress (reason=size) before any byte
// is inspected.
const maxProviderProfileBytes = 4096

// ProviderProfileStatus reports what happened to the raw provider profile.
type ProviderProfileStatus uint8

const (
	// ProviderProfileAbsent is the zero value: an attempt that never received a
	// profile reports absent without any write.
	ProviderProfileAbsent ProviderProfileStatus = iota
	ProviderProfileStored
	ProviderProfileTooLarge
	ProviderProfileDuplicate
	ProviderProfileLate
)

// SetProviderProfileRaw retains the raw (unvalidated) provider profile bytes
// for off-hot-path decoding. It performs only the size check; validation and
// decoding happen on the profile sink worker. First profile wins. A profile
// arriving after finalization is flagged late and not retained.
func (ap *AttemptProfile) SetProviderProfileRaw(raw []byte) ProviderProfileStatus {
	if ap == nil {
		return ProviderProfileAbsent
	}
	if len(raw) == 0 {
		return ProviderProfileAbsent
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	if len(raw) > maxProviderProfileBytes {
		if ap.providerProfileStat == ProviderProfileAbsent {
			ap.providerProfileStat = ProviderProfileTooLarge
		}
		return ProviderProfileTooLarge
	}
	if ap.finalizedLocked() {
		ap.providerProfileLate = true
		return ProviderProfileLate
	}
	if ap.providerProfileRaw != nil {
		ap.providerProfileStat = ProviderProfileDuplicate
		return ProviderProfileDuplicate
	}
	ap.providerProfileRaw = append([]byte(nil), raw...)
	ap.providerProfileStat = ProviderProfileStored
	return ProviderProfileStored
}

// ProviderProfileIngressStatus reports what happened at ingress (stored,
// absent, too large, duplicate) so the persisted invalid_reason can name it.
func (ap *AttemptProfile) ProviderProfileIngressStatus() ProviderProfileStatus {
	if ap == nil {
		return ProviderProfileAbsent
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	return ap.providerProfileStat
}

// SetTerminalUsage records the provider's terminal token counts (from the
// usage on inference_complete) for the consistency check against the profile.
func (ap *AttemptProfile) SetTerminalUsage(prompt, completion int) {
	if ap == nil {
		return
	}
	ap.mu.Lock()
	if !ap.terminalUsageSet { // first terminal wins, like every other outcome field
		ap.terminalPrompt, ap.terminalCompletion, ap.terminalUsageSet = prompt, completion, true
	}
	ap.mu.Unlock()
}

// TerminalUsage returns the recorded terminal token counts and whether any
// terminal usage was recorded.
func (ap *AttemptProfile) TerminalUsage() (prompt, completion int, ok bool) {
	if ap == nil {
		return 0, 0, false
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	return ap.terminalPrompt, ap.terminalCompletion, ap.terminalUsageSet
}

// ProviderProfileRaw returns the retained raw bytes (nil when none) and whether
// a late profile was observed.
func (ap *AttemptProfile) ProviderProfileRaw() (raw []byte, late bool) {
	if ap == nil {
		return nil, false
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	return ap.providerProfileRaw, ap.providerProfileLate
}

// SetOutcome records the closed-vocabulary outcome fields. Later writers do
// not overwrite a non-empty value, so the first terminal classification wins.
func (ap *AttemptProfile) SetOutcome(finalStatus, errorReason, terminalCause, providerOutcome, clientOutcome string) {
	if ap == nil {
		return
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	if ap.finalStatus == "" {
		ap.finalStatus = finalStatus
	}
	if ap.errorReason == "" {
		ap.errorReason = errorReason
	}
	if ap.terminalCause == "" {
		ap.terminalCause = terminalCause
	}
	if ap.providerOutcome == "" {
		ap.providerOutcome = providerOutcome
	}
	if ap.clientOutcome == "" {
		ap.clientOutcome = clientOutcome
	}
}

// Outcome returns the recorded outcome fields.
func (ap *AttemptProfile) Outcome() (finalStatus, errorReason, terminalCause, providerOutcome, clientOutcome string) {
	if ap == nil {
		return "", "", "", "", ""
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	return ap.finalStatus, ap.errorReason, ap.terminalCause, ap.providerOutcome, ap.clientOutcome
}

// Dispatched reports whether the attempt's frame reached the wire (write
// completed). Reserve-only, queue-only and write-failed attempts are not
// dispatched and are closed at their failure site.
func (ap *AttemptProfile) Dispatched() bool {
	return ap != nil && ap.WriteDoneUS.Load() != 0
}

// AttemptStamp names an attempt-level stamp for the nil-safe Mark helpers.
type AttemptStamp uint8

const (
	StampAttemptStart AttemptStamp = iota
	StampReserveLockAcquired
	StampReserveDone
	StampQueued
	StampDequeued
	StampTopupDone
	StampEncrypted
	StampWriteSubmitted
	StampWriteDequeued
	StampWriteDone
	StampAccepted
	StampFirstChunkIngress
	StampFirstChunkDequeued
	StampFirstContentIngress
	StampFirstContent
	StampCancelSent
	StampCompleteIngress
)

func (ap *AttemptProfile) field(s AttemptStamp) *atomic.Int64 {
	switch s {
	case StampAttemptStart:
		return &ap.AttemptStartUS
	case StampReserveLockAcquired:
		return &ap.ReserveLockAcquiredUS
	case StampReserveDone:
		return &ap.ReserveDoneUS
	case StampQueued:
		return &ap.QueuedUS
	case StampDequeued:
		return &ap.DequeuedUS
	case StampTopupDone:
		return &ap.TopupDoneUS
	case StampEncrypted:
		return &ap.EncryptedUS
	case StampWriteSubmitted:
		return &ap.WriteSubmittedUS
	case StampWriteDequeued:
		return &ap.WriteDequeuedUS
	case StampWriteDone:
		return &ap.WriteDoneUS
	case StampAccepted:
		return &ap.AcceptedUS
	case StampFirstChunkIngress:
		return &ap.FirstChunkIngressUS
	case StampFirstChunkDequeued:
		return &ap.FirstChunkDequeuedUS
	case StampFirstContentIngress:
		return &ap.FirstContentIngressUS
	case StampFirstContent:
		return &ap.FirstContentUS
	case StampCancelSent:
		return &ap.CancelSentUS
	case StampCompleteIngress:
		return &ap.CompleteIngressUS
	}
	return nil
}

// Mark stamps now into the named field (nil-safe, first-write-wins).
func (ap *AttemptProfile) Mark(s AttemptStamp) {
	if ap == nil || ap.parent == nil {
		return
	}
	ap.parent.Stamp(ap.field(s))
}

// MarkAt stamps a previously captured time into the named field (nil-safe).
func (ap *AttemptProfile) MarkAt(s AttemptStamp, t time.Time) {
	if ap == nil || ap.parent == nil {
		return
	}
	ap.parent.StampAt(ap.field(s), t)
}

// Get returns the stored offset for a stamp (0 = unset), nil-safe.
func (ap *AttemptProfile) Get(s AttemptStamp) int64 {
	if ap == nil {
		return 0
	}
	f := ap.field(s)
	if f == nil {
		return 0
	}
	return f.Load()
}
