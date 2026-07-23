package api

// Coordinator request actor.
//
// A requestActor is the single per-logical-request serialization point for the
// terminal-state decisions that used to be decided by goroutine scheduling and
// independent channel/timer ordering. One actor owns one inbound logical
// request; its (at most two concurrent — primary + one speculative backup)
// provider attempts are registered under it. Every terminal decision is taken
// under the actor's sync.Mutex, so ordering is determined by CALL ORDER, not by
// which goroutine the Go scheduler happens to run first.
//
// It closes the following races from the 2026-07-20 generation-deadline
// incident report:
//
//   - Race #1 "Provider frame order does not determine the winning terminal":
//     the provider WebSocket read loop calls claimAttemptTerminal SYNCHRONOUSLY
//     (in wire order) before launching the slow async billing work, so the FIRST
//     decoded terminal for an attempt wins under the mutex — a later-decoded
//     error can no longer beat an earlier-decoded completion just because the
//     completion's billing goroutine was scheduled later.
//
//   - Race #2 "Billing can complete while the client sees a timeout": the
//     client-facing timeout timer claims a terminalTimeout through the same
//     mutex before telling the client it timed out. If a provider terminal
//     already won the attempt, the claim is rejected and the timer path keeps
//     waiting for the real terminal instead of contradicting billing.
//
//   - Race #3 / speculative winner: selectWinner is one durable compare-and-set
//     from "no winner" to the committing attempt that atomically marks every
//     other active attempt a speculative_loser. Once a winner is selected, a
//     loser's later terminal is rejected. The one residual slice — a loser whose
//     terminal is decoded BEFORE the relay reaches selectWinner (both attempts
//     still active, no winner yet) — stays gated exactly as legacy today: the
//     actor can only ever SUPPRESS a settlement, never add one, so it is
//     money-neutral versus current behavior. Fully closing that slice (gating
//     billing on the durable winner) is the later finance-on-journal step, not
//     this one.
//
// AUTHORITY BOUNDARY (this step): the actor's in-memory CAS is the authoritative
// control-flow decision. It best-effort MIRRORS each decision into the durable
// settlement journal (coordinator/store) so the journal stops being inert and
// step 7 has real production shape to build on, but journaling is money-neutral
// (see journalReservation), never blocks the request, and a journal
// failure/mismatch can only log+metric — it can never change the client-visible
// or financial outcome. The existing process-local reservation/billing code in
// registry/reservations/provider.go remains authoritative for money in this
// step; the actor only decides ordering/winner/retry and stops the client timer.

import (
	"sync"
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// terminalKind enumerates the terminal events an attempt can accept. The first
// one claimed for an attempt wins; all later ones are telemetry-only.
type terminalKind int

const (
	terminalNone       terminalKind = iota
	terminalComplete                // provider inference_complete
	terminalError                   // provider inference_error
	terminalTimeout                 // coordinator-side attempt/client timeout
	terminalDisconnect              // provider disconnect
	terminalCancel                  // client cancellation / request fence
)

func (k terminalKind) String() string {
	switch k {
	case terminalComplete:
		return "complete"
	case terminalError:
		return "error"
	case terminalTimeout:
		return "timeout"
	case terminalDisconnect:
		return "disconnect"
	case terminalCancel:
		return "cancel"
	default:
		return "none"
	}
}

// attemptDisposition tracks an attempt's role in winner arbitration. It mirrors
// the store's AttemptDisposition but is the fast in-memory copy the actor uses
// for its authoritative decisions.
type attemptDisposition int

const (
	dispActive attemptDisposition = iota
	dispWinner
	dispLoser
	dispFailedRetry
)

// attemptSlot is the actor's per-attempt record.
type attemptSlot struct {
	attemptID   string
	providerID  string
	role        string // "primary" | "backup"
	ordinal     int    // dispatch attempt ordinal
	terminal    terminalKind
	disposition attemptDisposition
}

// requestActor serializes terminal/winner/retry decisions for one logical
// request. All mutable state is guarded by mu.
type requestActor struct {
	logicalID string
	table     *actorTable

	// journal runs a best-effort settlement-journal op. In production it hands
	// the op to the async telemetry sink; tests may inject a synchronous runner
	// so journal rows are observable deterministically. It never affects the
	// in-memory decision.
	journal      func(func())
	store        store.SettlementStore
	onJournalErr func(op string, err error)

	// Immutable request metadata used for journaling only.
	consumerAccount string
	model           string
	publicModel     string
	endpoint        string
	stream          bool
	budgetMS        int64

	reservedOnce sync.Once
	ingressSeq   atomic.Uint64

	mu          sync.Mutex
	attempts    map[string]*attemptSlot
	attemptIDs  []string
	winner      string
	winnerEpoch int64
	fenced      bool
	fenceCause  string
}

// nextIngress returns a strictly increasing per-actor sequence used to keep the
// journaled terminal/winner/fence rows monotonic in the store.
func (a *requestActor) nextIngress() uint64 { return a.ingressSeq.Add(1) }

// actorTable maps a provider attempt (request) ID to its owning requestActor so
// the provider read loop — which only knows the attempt ID — can reach the
// actor. Binding is additive: an attempt with no actor falls back to the legacy
// (pre-actor) code path, so the actor is never able to suppress a terminal for a
// path that was not wired to it.
type actorTable struct {
	mu        sync.RWMutex
	byAttempt map[string]*requestActor
}

func newActorTable() *actorTable {
	return &actorTable{byAttempt: make(map[string]*requestActor)}
}

func (t *actorTable) lookup(attemptID string) *requestActor {
	if t == nil || attemptID == "" {
		return nil
	}
	t.mu.RLock()
	defer t.mu.RUnlock()
	return t.byAttempt[attemptID]
}

func (t *actorTable) bind(attemptID string, actor *requestActor) {
	if t == nil || attemptID == "" || actor == nil {
		return
	}
	t.mu.Lock()
	t.byAttempt[attemptID] = actor
	t.mu.Unlock()
}

func (t *actorTable) unbind(attemptIDs []string) {
	if t == nil || len(attemptIDs) == 0 {
		return
	}
	t.mu.Lock()
	for _, id := range attemptIDs {
		delete(t.byAttempt, id)
	}
	t.mu.Unlock()
}

// newRequestActor builds an actor for one logical request. The Server wires the
// journal runner, store, and error sink; tests build it directly with a real
// in-memory store and a synchronous journal runner.
func (s *Server) newRequestActor(logicalID, consumerAccount, model, publicModel, endpoint string, stream bool, budgetMS int64) *requestActor {
	if budgetMS <= 0 {
		budgetMS = inferenceTimeout.Milliseconds()
	}
	a := &requestActor{
		logicalID:       logicalID,
		table:           s.actors,
		store:           s.store,
		consumerAccount: consumerAccount,
		model:           model,
		publicModel:     publicModel,
		endpoint:        endpoint,
		stream:          stream,
		budgetMS:        budgetMS,
		attempts:        make(map[string]*attemptSlot),
	}
	a.journal = func(op func()) {
		if !settlementJournalEnabled() {
			return
		}
		s.submitTelemetry("settlement_journal", op)
	}
	a.onJournalErr = func(name string, err error) {
		s.ddIncr("settlement.journal_error", []string{"op:" + name})
	}
	return a
}

// close unbinds all of the actor's attempts from the table. Called once the
// handler has fully delivered its response; any still-later provider terminal
// then falls back to the legacy path (which no-ops on an unknown request),
// exactly as before the actor existed.
func (a *requestActor) close() {
	if a == nil {
		return
	}
	a.mu.Lock()
	ids := append([]string(nil), a.attemptIDs...)
	a.mu.Unlock()
	a.table.unbind(ids)
}

// registerAttempt records a new provider attempt and binds it in the table so
// the read loop can find this actor. It is called once per dispatched attempt
// (primary/queued in the orchestrator, backup in the speculative path). The
// first registration also lazily journals the logical request reservation.
func (a *requestActor) registerAttempt(attemptID, providerID, role string, ordinal int) {
	if a == nil || attemptID == "" {
		return
	}
	a.mu.Lock()
	if _, exists := a.attempts[attemptID]; !exists {
		a.attempts[attemptID] = &attemptSlot{
			attemptID:   attemptID,
			providerID:  providerID,
			role:        role,
			ordinal:     ordinal,
			disposition: dispActive,
		}
		a.attemptIDs = append(a.attemptIDs, attemptID)
	}
	a.mu.Unlock()

	a.table.bind(attemptID, a)
	a.journalReservation()
	a.journalAttempt(attemptID, providerID, role, ordinal)
}

// claimAttemptTerminal is the synchronous first-terminal-wins gate. It reports
// whether THIS caller won the attempt's terminal. A rejected claim means the
// event is telemetry-only: a terminal was already accepted for the attempt, the
// attempt is a speculative loser, or a different attempt already won the logical
// request. Ordering is decided here, under the mutex, not by goroutine
// scheduling — the fix for incident race #1 and the timeout-vs-billing race #2.
func (a *requestActor) claimAttemptTerminal(attemptID string, kind terminalKind) bool {
	if a == nil {
		return true
	}
	a.mu.Lock()
	slot := a.attempts[attemptID]
	if slot == nil {
		a.mu.Unlock()
		return false
	}
	if slot.terminal != terminalNone {
		// First terminal already won this attempt (race #1 / late duplicate).
		a.mu.Unlock()
		return false
	}
	loser := slot.disposition == dispLoser || slot.disposition == dispFailedRetry ||
		(a.winner != "" && a.winner != attemptID)
	slot.terminal = kind
	if loser {
		if slot.disposition == dispActive {
			slot.disposition = dispLoser
		}
		a.mu.Unlock()
		return false
	}
	a.mu.Unlock()
	a.journalTerminalRow(attemptID, kind)
	return true
}

// selectWinner performs the single durable winner compare-and-set for the
// logical request: from "no winner" to attemptID, atomically marking every other
// still-active attempt a speculative_loser. It is called by the dispatch
// goroutine at content/clean-close commit, before any attempt-specific client
// write. Idempotent for the same winner; returns false if a different attempt
// already won, the request is fenced, or the attempt is unknown.
//
// Loser rejection is absolute only for terminals that arrive AFTER this call:
// a peer terminal decoded before selectWinner runs (both attempts still active)
// is still gated the legacy way, which the actor can only ever narrow, never
// widen (it never adds a settlement). Closing that slice by gating billing on
// the durable winner is the later finance-on-journal step.
func (a *requestActor) selectWinner(attemptID string) bool {
	if a == nil || attemptID == "" {
		return true
	}
	a.mu.Lock()
	slot := a.attempts[attemptID]
	if slot == nil {
		a.mu.Unlock()
		return false
	}
	if a.winner == attemptID {
		a.mu.Unlock()
		return true
	}
	if a.winner != "" || a.fenced {
		// A different attempt already won, or the request is fenced (client gone /
		// cancelled / budget expired): no new winner may be selected.
		a.mu.Unlock()
		return false
	}
	a.winner = attemptID
	slot.disposition = dispWinner
	for id, peer := range a.attempts {
		if id != attemptID && peer.disposition == dispActive {
			peer.disposition = dispLoser
		}
	}
	seq := a.nextIngress()
	epoch := a.winnerEpoch
	a.mu.Unlock()
	a.journalWinner(attemptID, epoch, seq)
	return true
}

// hasActivePeer reports whether an attempt other than the given one is still
// active (no terminal, not a loser). The live speculative dispatch loop already
// enforces the invariant that a failed attempt with a live eligible peer waits
// for the peer (via its single-goroutine race sub-waits), so this method backs
// the actor's assertion of that invariant in tests rather than driving control
// flow itself.
func (a *requestActor) hasActivePeer(attemptID string) bool {
	if a == nil {
		return false
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for id, slot := range a.attempts {
		if id == attemptID {
			continue
		}
		if slot.disposition == dispActive && slot.terminal == terminalNone {
			return true
		}
	}
	return false
}

// retryReleaseWinner clears a winner that failed before any client-visible
// output so a replacement attempt can be created. The current coordinator
// dispatcher never retries AFTER selecting a winner (it commits on first content
// and streams), so this has no live caller today; it is implemented and tested
// so the actor already models the invariant the durable journal enforces, and
// journals ReleaseRequestWinnerForRetry. It succeeds only when attemptID is the
// current winner and no other attempt is still active.
func (a *requestActor) retryReleaseWinner(attemptID string) bool {
	if a == nil || attemptID == "" {
		return false
	}
	a.mu.Lock()
	slot := a.attempts[attemptID]
	if slot == nil || a.winner != attemptID || a.fenced {
		a.mu.Unlock()
		return false
	}
	// The winner must have failed with a retryable terminal; a clean completion
	// (or a not-yet-terminal winner) is never released for retry.
	if slot.terminal == terminalNone || slot.terminal == terminalComplete {
		a.mu.Unlock()
		return false
	}
	for id, peer := range a.attempts {
		if id != attemptID && peer.disposition == dispActive && peer.terminal == terminalNone {
			a.mu.Unlock()
			return false
		}
	}
	epoch := a.winnerEpoch
	a.winner = ""
	a.winnerEpoch++
	slot.disposition = dispFailedRetry
	a.mu.Unlock()
	a.journalRelease(attemptID, epoch)
	return true
}

// fence atomically freezes the logical request: no new winner, no retry. It
// models client cancellation / client-gone / budget expiry and is journaled via
// FenceRequest. In this step the live client-cancellation path still runs the
// existing cancelDispatch + parked-settlement machinery unchanged (that path is
// money-critical and stays authoritative), so fence is exercised through the
// actor's tests and journal; wiring it as the live cancellation owner belongs to
// the later cancellation-ownership step. Idempotent for the same cause.
func (a *requestActor) fence(cause string) bool {
	if a == nil {
		return false
	}
	a.mu.Lock()
	if a.fenced {
		a.mu.Unlock()
		return false
	}
	a.fenced = true
	a.fenceCause = cause
	seq := a.nextIngress()
	a.mu.Unlock()
	a.journalFence(cause, seq)
	return true
}

// ---- Server-side helpers that wrap the actor for the wired call sites ----

// acceptProviderTerminal is the read-loop gate for a decoded provider terminal
// (complete/error). It claims the attempt terminal SYNCHRONOUSLY in wire order
// and returns true when the caller should proceed with the (slow, async) billing
// / error handling; false when the terminal was superseded. Attempts with no
// bound actor fall back to the legacy path (always proceed).
//
// The reject path performs NO transport cleanup, on purpose. RemovePending is the
// legacy single-owner settlement/transport claim, owned by exactly one of: the
// WINNING provider-terminal handler (handleComplete/handleInferenceError), the
// dispatch loop's cancelDispatch for a speculative loser (which also refunds the
// loser's top-up), or the timeout path that won the actor claim
// (actorAcceptsClientTimeout). If this reject path also removed pending it would
// RACE those owners — e.g. steal the completion's RemovePending, making
// handleComplete drop billing and never close ChunkCh (a hung stream), or steal
// the loser's cancelDispatch removal and skip its top-up refund. So a superseded
// terminal is dropped to telemetry only.
func (s *Server) acceptProviderTerminal(providerID string, provider *registry.Provider, attemptID string, kind terminalKind) bool {
	actor := s.actors.lookup(attemptID)
	if actor == nil {
		return true
	}
	if actor.claimAttemptTerminal(attemptID, kind) {
		return true
	}
	s.ddIncr("inference.terminal_superseded", []string{"kind:" + kind.String()})
	return false
}

// actorAcceptsClientTimeout is the client-facing timer gate (race #2). It
// returns true when the caller may tell the client the request timed out; false
// when a provider terminal already won the attempt, in which case the caller
// must keep waiting for the real terminal instead of contradicting billing.
// Attempts with no bound actor keep the legacy always-timeout behavior.
//
// When the timeout WINS the claim, this path becomes the single RemovePending
// owner for the attempt: the provider's (possibly in-flight) completion/error
// will be rejected by acceptProviderTerminal, so handleComplete/
// handleInferenceError will not run and would otherwise leave the transport
// entry lingering until disconnect. Removing it here is race-free precisely
// because a won timeout claim guarantees no provider-terminal handler runs.
func (s *Server) actorAcceptsClientTimeout(pr *registry.PendingRequest) bool {
	if pr == nil {
		return true
	}
	actor := s.actors.lookup(pr.RequestID)
	if actor == nil {
		return true
	}
	if !actor.claimAttemptTerminal(pr.RequestID, terminalTimeout) {
		return false
	}
	if p := s.registry.GetProvider(pr.ProviderID); p != nil {
		if removed := p.RemovePending(pr.RequestID); removed != nil {
			s.chunkKeys.forget(removed.SessionPrivKey)
		}
		s.registry.SetProviderIdle(pr.ProviderID)
	}
	return true
}
