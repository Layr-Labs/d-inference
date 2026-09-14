package cacheattempt

import (
	"sync"
	"sync/atomic"
	"time"
)

// State owns preparation tickets, terminal closure and the current attempt.
// Its zero value is ready for preparation and must not be copied after use.
type State struct {
	attempt atomic.Pointer[Attempt]
	mu      sync.Mutex
	ticket  uint64
	closed  bool
}

// Begin revokes the previous preparation and resets caller-owned legacy
// metadata under the same lock. reset may be nil; otherwise it must only
// update that metadata and must not reenter State. Receipt cleanup follows
// after unlocking, so it cannot invert the registry's live publication locks.
func (s *State) Begin(reset func()) (ticket uint64, open bool) {
	s.mu.Lock()
	owner := s.attempt.Swap(nil)
	if owner != nil {
		owner.revoked.Store(true)
	}
	s.ticket++
	ticket, open = s.ticket, !s.closed
	if reset != nil {
		reset()
	}
	s.mu.Unlock()
	if owner != nil {
		owner.Forget()
	}
	return ticket, open
}

// Publish installs an attempt only while its preparation is still current.
// The caller must first revalidate its live generation/provider connection.
func (s *State) Publish(ticket uint64, owner *Attempt) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.ticket != ticket {
		return false
	}
	s.attempt.Store(owner)
	return true
}

// PublishLegacy applies protocol-0 metadata only to the current preparation.
// update runs under the same lock as Begin's reset and must not reenter State.
func (s *State) PublishLegacy(ticket uint64, update func()) {
	s.mu.Lock()
	if s.ticket == ticket && !s.closed {
		update()
	}
	s.mu.Unlock()
}

// Terminal permanently closes preparation and revokes queued frames. Already
// accepted frames retain their participation, and receipts retain their
// terminal grace through the original directory outside the request lock.
func (s *State) Terminal(now time.Time) {
	s.mu.Lock()
	s.closed = true
	s.ticket++
	owner := s.attempt.Load()
	if owner != nil {
		owner.revoked.Store(true)
	}
	s.mu.Unlock()
	if owner != nil && owner.receipts != nil {
		owner.receipts.MarkCacheAttemptTerminal(owner.metadata.Nonce, now)
	}
}

func (s *State) Snapshot() Snapshot { return Snapshot{owner: s.attempt.Load()} }

// Participates includes prepared and accepted attempts, but excludes frames
// made cold at dequeue. Revocation cannot undo an already accepted frame.
func (s *State) Participates() bool {
	owner := s.attempt.Load()
	return owner != nil && owner.dispatchState.Load() != dispatchCold
}
