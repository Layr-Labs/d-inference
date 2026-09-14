package dispatchplan

import (
	"context"
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Probe fans capacity probes out to every unconsumed, unquoted,
// quote-capable entry of plan and returns a channel of settled outcomes; the
// channel closes once every probe has resolved (quote, transport failure, or
// window expiry). Legacy entries are skipped silently — they stay in the
// unconfirmed mid tier. Bounded by construction: a plan retains at most
// MaxAlternates entries, so the fanout is ≤ 8 sender goroutines
// plus one collector, all panic-guarded via saferun.
//
// The collector applies each outcome to the plan itself (affirmative →
// ConfirmEntry, negative/timeout/sendfailed → DemoteEntry) BEFORE forwarding
// it, so a consumer that never reads the channel still gets a correctly
// re-ranked plan; the channel is buffered to the probe count, so an
// abandoned consumer never wedges the collector either.
//
// Probes ride the bounded DATA lane (Provider.WriteText): queue-full is the
// natural shedding signal and settles the probe as SendFailed immediately.
// The strict control lane is reserved for cancel/attestation/trust — a probe
// storm there would starve exactly the frames that must never queue.
func (t *Probes[C]) Probe(plan *Plan[C], shape ProbeShape, window time.Duration, transport Transport[C]) <-chan QuoteOutcome {
	out := make(chan QuoteOutcome, MaxAlternates)
	targets := plan.probeTargets()
	if len(targets) == 0 || window <= 0 {
		close(out)
		return out
	}

	deliveries := make(chan quoteDelivery, len(targets))
	// outstanding maps quote_id → provider ID for the collector's timeout
	// attribution. Owned by the collector after fanout; senders never touch it.
	outstanding := make(map[string]string, len(targets))
	expiresAt := time.Now().Add(window)
	for _, target := range targets {
		provider := target.Connection
		providerID := target.View.ProviderID
		if !transport.Ready(provider) {
			continue
		}
		quoteID, err := newQuoteID()
		if err != nil {
			// No entropy, no probe: the entry simply stays unconfirmed.
			transport.Logger().Error("capacity probe id generation failed", "provider_id", providerID, "error", err)
			continue
		}
		payload, err := json.Marshal(&protocol.CapacityProbeMessage{
			Type:                protocol.TypeCapacityProbe,
			QuoteID:             quoteID,
			Model:               shape.Model,
			PromptTokensBucket:  bucketPromptTokens(shape.PromptTokens),
			MaxOutputTokens:     shape.MaxOutputTokens,
			RequiresVision:      shape.RequiresVision,
			VisionImageCount:    shape.VisionImageCount,
			DeadlineRemainingMS: max(shape.DeadlineRemaining.Milliseconds(), 0),
		})
		if err != nil {
			transport.Logger().Error("capacity probe marshal failed", "provider_id", providerID, "error", err)
			continue
		}
		// Register BEFORE sending so a quote racing the sender's return can
		// never miss its entry.
		t.add(quoteID, &pendingQuote{
			providerID: providerID,
			expiresAt:  expiresAt,
			deliver:    deliveries,
		})
		outstanding[quoteID] = providerID
		saferun.Go(transport.Logger(), "registry.capacityProbeSend", func() {
			// The write is useless past the quote window — bound it there
			// rather than letting a wedged data lane hold the goroutine.
			ctx, cancel := context.WithTimeout(context.Background(), window)
			defer cancel()
			if writeErr := transport.Write(provider, ctx, payload); writeErr != nil {
				// Queue full / writer stopped / timeout: settle as SendFailed
				// now IF this probe is still ours to settle (a disconnect may
				// have claimed it first — take() decides exactly once).
				if pq := t.take(quoteID); pq != nil {
					deliveries <- quoteDelivery{quoteID: quoteID, providerID: providerID}
				}
			}
		})
	}
	if len(outstanding) == 0 {
		close(out)
		return out
	}

	saferun.Go(transport.Logger(), "registry.capacityQuoteCollector", func() {
		defer close(out)
		timer := time.NewTimer(window)
		defer timer.Stop()
		for len(outstanding) > 0 {
			select {
			case d := <-deliveries:
				delete(outstanding, d.quoteID)
				out <- applyQuoteDelivery(plan, d)
			case <-timer.C:
				// Window over. Claim every still-silent probe as a Timeout;
				// an entry already claimed elsewhere (nil take) has a
				// delivery in flight — keep looping, it resolves on the
				// deliveries branch. The timer fires once, so the loop can
				// only continue on deliveries afterwards, and every
				// unclaimed entry is gone — termination is guaranteed.
				for quoteID, providerID := range outstanding {
					if t.take(quoteID) == nil {
						continue
					}
					delete(outstanding, quoteID)
					plan.DemoteEntry(providerID)
					out <- QuoteOutcome{ProviderID: providerID, Timeout: true}
				}
			}
		}
	})
	return out
}
