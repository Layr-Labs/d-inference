package dispatchplan

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// DropReason preserves the registry reply logger's bounded disposition.
type DropReason string

const (
	QuoteAccepted         DropReason = ""
	QuoteUnknown          DropReason = "unknown_or_late_quote_id"
	QuoteProviderMismatch DropReason = "provider_mismatch"
	QuoteExpired          DropReason = "expired"
)

// Handle resolves one provider capacity_quote against its
// outstanding probe. Called from the api provider read loop. Invalid quotes
// are dropped with a bounded reason:
//   - unknown/late quote_id (the probe already settled, or was never ours);
//   - provider mismatch (a provider must never answer another's probe — the
//     entry is deliberately LEFT registered so the bound provider's own
//     answer, or the window sweep, still settles it);
//   - expired (past the probe window; left for the collector's timeout sweep
//     so the outcome accounting stays single-owner).
func (t *Probes[C]) Handle(providerID string, msg *protocol.CapacityQuoteMessage) DropReason {
	if msg == nil || msg.QuoteID == "" {
		return QuoteAccepted
	}
	t.mu.Lock()
	pq, ok := t.pending[msg.QuoteID]
	if !ok {
		t.mu.Unlock()
		return QuoteUnknown
	}
	if pq.providerID != providerID {
		t.mu.Unlock()
		return QuoteProviderMismatch
	}
	if time.Now().After(pq.expiresAt) {
		t.mu.Unlock()
		return QuoteExpired
	}
	delete(t.pending, msg.QuoteID)
	pq.deliver <- quoteDelivery{quoteID: msg.QuoteID, providerID: providerID, quote: msg}
	t.mu.Unlock()
	return QuoteAccepted
}
