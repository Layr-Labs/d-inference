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
	store                store.AutopilotRewardsStore
	logger               *slog.Logger
	sessionID, accountID string
	pending              []earningsfloor.Consent
}

func (s *Owner) newAutopilotRewardCapture(sessionID, authenticatedAccountID string) *autopilotRewardCapture {
	if authenticatedAccountID == "" {
		return nil
	}
	rewards, ok := store.As[store.AutopilotRewardsStore](s.store)
	if !ok {
		s.logger.Warn("autopilot consent tracking unavailable", "reason", "unsupported_store")
		return nil
	}
	return &autopilotRewardCapture{store: rewards, logger: s.logger, sessionID: sessionID, accountID: authenticatedAccountID}
}

func (c *autopilotRewardCapture) observe(ctx context.Context, provider *registry.Provider, receivedAt time.Time) bool {
	if c == nil {
		return true
	}
	// A full queue may need a retry before adding this observation. Both
	// flushes share one deadline rather than doubling the read-loop stall.
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	optedIn, supported := provider.AutopilotRewardConsentSnapshot()
	n := len(c.pending)
	duplicate := n > 0 && c.pending[n-1].OptedIn == optedIn && c.pending[n-1].Supported == supported
	if n == maxPendingAutopilotConsents && !duplicate {
		c.flush(ctx, nil)
		if len(c.pending) == maxPendingAutopilotConsents {
			// No silent drop or unbounded memory on a permanently unbound
			// or unavailable store. Only tracking overload closes the socket.
			c.logger.Error("autopilot consent tracking overflow", "pending", len(c.pending))
			return false
		}
	}
	// Even an unbound session's repeat must reach the raw journal with its
	// current timestamp. Only failed adjacent duplicates are compacted below;
	// this transient extra observation does not add a pending transition.
	c.flush(ctx, &earningsfloor.Consent{
		SessionID: c.sessionID, AccountID: c.accountID, OptedIn: optedIn, Supported: supported, At: receivedAt,
	})
	return true
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
	previousRetained := false
	retain := func(index int, declaration earningsfloor.Consent) {
		// Compact only the fresh duplicate. Older equal pending values may
		// straddle an intervening transition that already succeeded.
		if current != nil && index == len(pending)-1 && previousRetained {
			last := c.pending[len(c.pending)-1]
			if last.OptedIn == declaration.OptedIn && last.Supported == declaration.Supported {
				return
			}
		}
		c.pending = append(c.pending, declaration)
		previousRetained = true
	}
	for i, declaration := range pending {
		_, err := c.store.ObserveAutopilotConsent(operation, declaration)
		if err == nil {
			// A successful intervening transition must not make two failed
			// equal values adjacent for compaction.
			previousRetained = false
			continue
		}
		if errors.Is(err, earningsfloor.ErrIdentity) {
			// The store journals authenticated unbound declarations durably
			// before returning ErrIdentity. Keep retrying the original time,
			// but also journal later transitions before this session can end.
			retain(i, declaration)
			continue
		}
		for j := i; j < len(pending); j++ {
			retain(j, pending[j])
		}
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
	if len(c.pending) == 0 {
		c.pending = nil
		return
	}
	c.logger.Warn("autopilot consent capture pending", "reason", "identity_unverified", "pending", len(c.pending))
}
