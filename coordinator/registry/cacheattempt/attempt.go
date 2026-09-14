package cacheattempt

import (
	"sync/atomic"
	"time"
)

const (
	dispatchPrepared uint32 = iota
	dispatchAccepted
	dispatchCold
)

// Receipts owns the directory entries for an attempt. Its operations are
// called only after the request's preparation lock has been released.
type Receipts interface {
	ForgetCacheAttempt(nonce string)
	MarkCacheAttemptTerminal(nonce string, now time.Time)
}

// Metadata is immutable receipt identity, never prompt content. It must not
// be logged or persisted, and its presence alone does not authorize dispatch.
type Metadata struct {
	Nonce        string
	Scope        string
	BoundaryMode string
}

// Attempt binds one preparation to its original generation and receipts.
// Create it before publication; all later mutation is private and atomic.
type Attempt struct {
	receipts      Receipts
	generation    *Generation
	metadata      Metadata
	revoked       atomic.Bool
	dispatchState atomic.Uint32
}

func New(generation *Generation, receipts Receipts, metadata Metadata) *Attempt {
	return &Attempt{receipts: receipts, generation: generation, metadata: metadata}
}

// Forget removes the receipt entry after failed publication or replacement.
func (a *Attempt) Forget() {
	if a.receipts != nil {
		a.receipts.ForgetCacheAttempt(a.metadata.Nonce)
	}
}
