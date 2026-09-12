package registry

// AttemptProfile lifecycle: an attempt finalizes exactly once when BOTH the
// handler half and the terminal half are done; a fallback timer armed at the
// handler half guarantees finalization when no terminal ever arrives, and
// ClaimTerminal lets provider ingress suppress that fallback.

import (
	"time"
)

// ProfilePart identifies which half of an attempt's lifecycle has completed.
type ProfilePart uint8

const (
	// ProfilePartHandler is set when the dispatch/handler goroutine is done
	// with the attempt (it retried, exhausted, or returned to the client).
	ProfilePartHandler ProfilePart = iota
	// ProfilePartTerminal is set when the provider terminal (complete/error),
	// a coordinator-synthetic terminal, or the settlement grace expiry landed.
	ProfilePartTerminal
)

// ProfileFinalizeFn receives a fully-finalized attempt. It runs on whichever
// goroutine completed the second half (or the fallback timer) and must be
// non-blocking: the api layer enqueues the store write onto the profile sink.
type ProfileFinalizeFn func(rp *RequestProfile, ap *AttemptProfile)

// finalizedLocked reports whether both halves completed (mu must be held or
// the caller must be the finalizer).
func (ap *AttemptProfile) finalizedLocked() bool {
	return ap.parts.Load() >= 2
}

// Complete marks one half of the attempt lifecycle as done. The second call
// (either order) finalizes exactly once. Calling the same part twice is
// harmless only if the caller guards it; both halves count, so callers must
// invoke each part at most once per attempt (TerminalOnce/HandlerOnce below
// enforce that).
func (ap *AttemptProfile) complete(part ProfilePart) {
	if ap == nil {
		return
	}
	n := ap.parts.Add(1)
	if part == ProfilePartHandler && n < 2 {
		ap.armFallback()
	}
	if n >= 2 {
		ap.runFinalize()
	}
}

// CompleteHandler marks the handler half done (idempotent per attempt).
func (ap *AttemptProfile) CompleteHandler() {
	if ap == nil {
		return
	}
	ap.mu.Lock()
	if ap.handlerDone {
		ap.mu.Unlock()
		return
	}
	ap.handlerDone = true
	ap.mu.Unlock()
	ap.complete(ProfilePartHandler)
}

// CompleteTerminal marks the terminal half done (idempotent per attempt).
func (ap *AttemptProfile) CompleteTerminal() {
	if ap == nil {
		return
	}
	ap.mu.Lock()
	if ap.terminalRecorded {
		ap.mu.Unlock()
		return
	}
	ap.terminalRecorded = true
	ap.mu.Unlock()
	ap.complete(ProfilePartTerminal)
}

// CompleteTerminalUnlessClaimed completes the terminal half only when no
// provider terminal frame owns it, atomically: the route-outcome funnel uses
// it so a claim landing between a separate check and the completion cannot
// finalize the record before the owner has retained its usage and profile.
// Returns false when a frame owns the terminal (that frame completes it).
func (ap *AttemptProfile) CompleteTerminalUnlessClaimed() bool {
	if ap == nil {
		return false
	}
	ap.mu.Lock()
	if ap.terminalClaimed || ap.terminalRecorded {
		ap.mu.Unlock()
		return false
	}
	ap.terminalRecorded = true // same once-only guard as CompleteTerminal
	ap.mu.Unlock()
	ap.complete(ProfilePartTerminal)
	return true
}

// TerminalClaimed reports whether a provider terminal frame owns the terminal
// half (it will complete it itself once its outcome is written).
func (ap *AttemptProfile) TerminalClaimed() bool {
	if ap == nil {
		return false
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	return ap.terminalClaimed
}

// TerminalRecorded reports whether the terminal half has landed.
func (ap *AttemptProfile) TerminalRecorded() bool {
	if ap == nil {
		return false
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	return ap.terminalRecorded
}

func (ap *AttemptProfile) armFallback() {
	rp := ap.parent
	if rp == nil || rp.fallbackGrace <= 0 {
		return
	}
	ap.mu.Lock()
	// A terminal that landed between parts.Add and this arm already finalized
	// the attempt (runFinalize saw fallback == nil); never arm a timer for a
	// finalized attempt or it would live for the whole grace.
	if ap.finalizedLocked() {
		ap.mu.Unlock()
		return
	}
	if ap.fallback == nil {
		ap.fallback = time.AfterFunc(rp.fallbackGrace, func() {
			// No terminal within the grace: finalize with what we have — unless a
			// terminal was observed at ingress and is still being processed
			// (slow settlement); then the real CompleteTerminal will follow. The
			// check and the claim are one critical section so a terminal that
			// lands in between can never lose its outcome to the fallback.
			ap.mu.Lock()
			if ap.terminalClaimed || ap.terminalRecorded {
				ap.mu.Unlock()
				return
			}
			ap.terminalRecorded = true
			if ap.providerOutcome == "" {
				ap.providerOutcome = "no_terminal"
			}
			ap.mu.Unlock()
			ap.complete(ProfilePartTerminal)
		})
	}
	ap.mu.Unlock()
}

func (ap *AttemptProfile) runFinalize() {
	ap.once.Do(func() {
		if rp := ap.parent; rp != nil {
			rp.Stamp(&ap.FinalizedUS)
		}
		ap.mu.Lock()
		if ap.fallback != nil {
			ap.fallback.Stop()
			ap.fallback = nil
		}
		ap.mu.Unlock()
		rp := ap.parent
		if rp == nil || rp.finalize == nil {
			return
		}
		rp.finalize(rp, ap)
	})
}

// Finalized reports whether the attempt has been finalized.
func (ap *AttemptProfile) Finalized() bool {
	if ap == nil {
		return false
	}
	return ap.parts.Load() >= 2
}

// ClaimTerminal records that a provider terminal for this attempt has been
// observed at ingress and is being processed. It suppresses the no-terminal
// fallback (which could otherwise win a race against slow settlement work)
// without completing the terminal half; CompleteTerminal still follows.
// ClaimTerminal returns true for the first claimant only: a duplicate terminal
// frame for the same attempt must not retain usage or a profile over the
// frame that actually settles (retention is gated on the returned ownership).
func (ap *AttemptProfile) ClaimTerminal() bool {
	if ap == nil {
		return false
	}
	ap.mu.Lock()
	defer ap.mu.Unlock()
	if ap.terminalClaimed {
		return false
	}
	ap.terminalClaimed = true
	return true
}
