package provider

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

const maxPendingAutopilotConsents = 256

// The serial socket reader owns pending declarations. These are synchronous
// writes, independent of the reward worker and residency controller. A retry
// must never replace the first receive time or skip a short opt-in/opt-out.
type autopilotRewardCapture struct {
	store                store.AutopilotConsentJournal
	registry             *registry.Registry
	logger               *slog.Logger
	sessionID, accountID string
	pending              []earningsfloor.Consent
}

func (s *Owner) newAutopilotRewardCapture(sessionID, authenticatedAccountID string) *autopilotRewardCapture {
	if authenticatedAccountID == "" {
		return nil
	}
	rewards, ok := store.As[store.AutopilotConsentJournal](s.store)
	if !ok {
		s.logger.Warn("autopilot consent tracking unavailable", "reason", "unsupported_store")
		return nil
	}
	return &autopilotRewardCapture{store: rewards, registry: s.registry, logger: s.logger, sessionID: sessionID, accountID: authenticatedAccountID}
}

func (c *autopilotRewardCapture) observe(ctx context.Context, provider *registry.Provider, receivedAt time.Time) bool {
	if c == nil {
		return true
	}
	// A full queue may need a retry before adding this observation. Both
	// flushes share one deadline rather than doubling the read-loop stall.
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	declaration := c.registry.AutopilotRewardDeclarationAt(provider, receivedAt)
	declaration.SessionID, declaration.AccountID, declaration.At = c.sessionID, c.accountID, receivedAt
	n := len(c.pending)
	duplicate := n > 0 && sameAutopilotRewardState(c.pending[n-1], declaration)
	if n == maxPendingAutopilotConsents && !duplicate {
		c.flush(ctx, nil)
		if len(c.pending) == maxPendingAutopilotConsents {
			// No silent drop or unbounded memory on an unavailable journal.
			// Successful unbound writes do not stay in this retry queue.
			c.logger.Error("autopilot consent tracking overflow", "pending", len(c.pending))
			return false
		}
	}
	// Even an unbound session's repeat must reach the raw journal with its
	// current timestamp. Only failed adjacent duplicates are compacted below;
	// this transient extra observation does not add a pending transition.
	c.flush(ctx, &declaration)
	return true
}

func sameAutopilotRewardState(a, b earningsfloor.Consent) bool {
	return a.OptedIn == b.OptedIn && a.Supported == b.Supported && a.Qualified == b.Qualified &&
		a.Chip == b.Chip && a.MemoryGB == b.MemoryGB
}

func (c *autopilotRewardCapture) flush(ctx context.Context, current *earningsfloor.Consent) {
	if c == nil || (len(c.pending) == 0 && current == nil) {
		return
	}
	// Bound the entire retry batch, not each declaration, so an unavailable
	// store cannot hold attestation and inference delivery behind N timeouts.
	operation, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	pending := c.pending
	if current != nil {
		pending = append(pending, *current)
	}
	c.pending = c.pending[:0]
	for i, declaration := range pending {
		err := c.store.RecordAutopilotConsent(operation, declaration)
		if err == nil {
			continue
		}
		remaining := pending[i:]
		// Only compact the fresh adjacent duplicate; every older queued
		// transition keeps its original receive time and position.
		if last := len(remaining) - 1; current != nil && last > 0 &&
			sameAutopilotRewardState(remaining[last-1], remaining[last]) {
			remaining = remaining[:last]
		}
		c.pending = append(c.pending, remaining...)
		reason := "storage_error"
		if errors.Is(err, context.DeadlineExceeded) {
			reason = "timeout"
		} else if errors.Is(err, context.Canceled) {
			reason = "canceled"
		}
		// Never log store error strings, account identifiers or provider data.
		c.logger.Warn("autopilot consent capture pending", "reason", reason, "pending", len(c.pending))
		return
	}
	c.pending = nil
}
