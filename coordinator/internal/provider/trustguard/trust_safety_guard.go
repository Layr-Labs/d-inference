package trustguard

import (
	"log/slog"
	"sync"
)

// trustSafetyGuard enforces global fail-closed health and identity-local
// revocation denial while journaled revocations converge with the store.
type Guard struct {
	logger                      *slog.Logger
	trustSafetyMu               sync.RWMutex
	trustSafetySticky           bool
	trustSafetyReplayBlocked    bool
	pendingHardUntrustKeyHashes map[string]int
}

func New(logger *slog.Logger, durable bool) *Guard {
	s := &Guard{logger: logger}
	if durable {
		s.pendingHardUntrustKeyHashes = make(map[string]int)
	}
	return s
}
