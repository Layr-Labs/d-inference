package registry

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Capacity probe fanout + quote correlation — routing v2 W2 (honesty channel).
//
// After the primary dispatches, the request's remaining plan alternates each
// get a capacity_probe (bounded DATA lane — a probe storm must shed naturally
// at the 128-deep writer queue, never starve the control lane's cancels and
// attestations) and answer with a capacity_quote. Quotes CONFIRM or DEMOTE
// plan entries so retries and hedges consume provider-endorsed candidates;
// the coordinator's ledger remains the primary accounting (see
// protocol/capacity.go for the full account and the privacy invariant).
//
// Correlation copies the api-side challengeTracker pattern (api/provider.go):
// a mutex-guarded map keyed by the random request-local quote_id, resolved
// exactly once by whichever event settles it first — the provider's quote,
// the sender's write failure, a disconnect, or the collector's window expiry.

// CapacityProbeShape is the coordinator-side request shape a probe describes.
// PromptTokens is the coordinator's raw estimate; the wire message carries it
// bucketed (rounded UP to protocol.CapacityProbePromptBucketTokens) so a
// probed-but-never-chosen provider learns shape, not content.
type CapacityProbeShape struct {
	Model             string
	PromptTokens      int
	MaxOutputTokens   int
	RequiresVision    bool
	VisionImageCount  int
	DeadlineRemaining time.Duration
}

// QuoteOutcome is one probe's settled result, delivered on the channel
// ProbePlanCandidates returns. Exactly one of the three states holds:
// Quote != nil (the provider answered — affirmative or negative, per
// Quote.AdmissibleNow), Timeout (silent through the window), or SendFailed
// (writer queue full, write error, or the provider disconnected). By the time
// an outcome is readable the plan has ALREADY been updated (ConfirmEntry /
// DemoteEntry) — the channel is informational, for hedge timing and telemetry,
// never a step the dispatch loop must apply itself.
type QuoteOutcome struct {
	ProviderID string
	Quote      *protocol.CapacityQuoteMessage
	Timeout    bool
	SendFailed bool
}

// quoteDelivery is the tracker→collector handoff for one settled probe.
// quote == nil means transport failure (send error or disconnect).
type quoteDelivery struct {
	quoteID    string
	providerID string
	quote      *protocol.CapacityQuoteMessage
}

// pendingQuote is one outstanding probe: the provider binding the quote must
// come back from, the expiry after which a quote is too stale to act on, and
// the owning collector's delivery channel. The channel is buffered to the
// collector's full probe count and each entry delivers at most once (map
// removal is the claim), so delivering NEVER blocks — safe under t.mu.
type pendingQuote struct {
	providerID string
	expiresAt  time.Time
	deliver    chan<- quoteDelivery
}

// quoteTracker correlates capacity quotes with their probes by quote_id.
// LEAF mutex: nothing is called while holding t.mu except buffered channel
// sends, and no code path takes r.mu, p.mu, or a plan mu under it.
type quoteTracker struct {
	mu      sync.Mutex
	pending map[string]*pendingQuote
}

// add registers an outstanding probe. The opportunistic >1024 sweep (same
// idiom as the sibling cooldown maps) drops expired entries whose collector
// died before its window sweep — a leak only a panicked collector can create,
// since a live one takes back every silent entry at expiry.
func (t *quoteTracker) add(quoteID string, pq *pendingQuote) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.pending == nil {
		t.pending = make(map[string]*pendingQuote)
	}
	if len(t.pending) > 1024 {
		now := time.Now()
		for id, e := range t.pending {
			if now.After(e.expiresAt) {
				delete(t.pending, id)
			}
		}
	}
	t.pending[quoteID] = pq
}

// take claims an outstanding probe by quote_id, or nil when another settling
// event already claimed it. The removal IS the exactly-once guarantee.
func (t *quoteTracker) take(quoteID string) *pendingQuote {
	t.mu.Lock()
	defer t.mu.Unlock()
	pq := t.pending[quoteID]
	delete(t.pending, quoteID)
	return pq
}

// failProvider settles every outstanding probe bound to a disconnected
// provider as a transport failure. Delivering under t.mu is safe (buffered
// channels, one delivery per entry) and keeps claim+delivery atomic.
func (t *quoteTracker) failProvider(providerID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for id, pq := range t.pending {
		if pq.providerID != providerID {
			continue
		}
		delete(t.pending, id)
		pq.deliver <- quoteDelivery{quoteID: id, providerID: providerID}
	}
}

// capacityQuoteReady reports whether this connection has proven the wave-2
// capacity protocol: a heartbeat on THIS connection carried capacity_seq > 0
// (see the gate in Heartbeat). Legacy sessions are never probed — a frame
// type they do not implement would at best be ignored and at worst kill the
// connection, and their plan entries stay ledger-scored mid-tier by design
// (dual path until the fleet floor).
func (p *Provider) capacityQuoteReady() bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.capacityQuoteCapable
}

// bucketPromptTokens rounds a prompt-token estimate UP to the probe bucket
// granularity (privacy invariant: probes carry shape, never exact counts).
func bucketPromptTokens(tokens int) int {
	if tokens <= 0 {
		return 0
	}
	const bucket = protocol.CapacityProbePromptBucketTokens
	return (tokens + bucket - 1) / bucket * bucket
}

// newQuoteID mints the random, request-local probe correlation ID. 128 bits —
// deliberately NOT the public request ID, so a probed provider can never link
// a probe to a request it later serves.
func newQuoteID() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// HandleCapacityQuote resolves one provider capacity_quote against its
// outstanding probe. Called from the api provider read loop. Invalid quotes
// are dropped with a bounded reason:
//   - unknown/late quote_id (the probe already settled, or was never ours);
//   - provider mismatch (a provider must never answer another's probe — the
//     entry is deliberately LEFT registered so the bound provider's own
//     answer, or the window sweep, still settles it);
//   - expired (past the probe window; left for the collector's timeout sweep
//     so the outcome accounting stays single-owner).
func (r *Registry) HandleCapacityQuote(providerID string, msg *protocol.CapacityQuoteMessage) {
	if msg == nil || msg.QuoteID == "" {
		return
	}
	t := &r.capacityQuotes
	t.mu.Lock()
	pq, ok := t.pending[msg.QuoteID]
	if !ok {
		t.mu.Unlock()
		r.logger.Debug("dropping capacity quote", "reason", "unknown_or_late_quote_id", "provider_id", providerID)
		return
	}
	if pq.providerID != providerID {
		t.mu.Unlock()
		r.logger.Warn("dropping capacity quote", "reason", "provider_mismatch", "provider_id", providerID)
		return
	}
	if time.Now().After(pq.expiresAt) {
		t.mu.Unlock()
		r.logger.Debug("dropping capacity quote", "reason", "expired", "provider_id", providerID)
		return
	}
	delete(t.pending, msg.QuoteID)
	pq.deliver <- quoteDelivery{quoteID: msg.QuoteID, providerID: providerID, quote: msg}
	t.mu.Unlock()
}

// ProbePlanCandidates fans capacity probes out to every unconsumed, unquoted,
// quote-capable entry of plan and returns a channel of settled outcomes; the
// channel closes once every probe has resolved (quote, transport failure, or
// window expiry). Legacy entries are skipped silently — they stay in the
// unconfirmed mid tier. Bounded by construction: a plan retains at most
// dispatchPlanMaxAlternates entries, so the fanout is ≤ 8 sender goroutines
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
func (r *Registry) ProbePlanCandidates(plan *DispatchPlan, shape CapacityProbeShape, window time.Duration) <-chan QuoteOutcome {
	out := make(chan QuoteOutcome, dispatchPlanMaxAlternates)
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
		provider := target.provider
		providerID := target.view.ProviderID
		if !provider.capacityQuoteReady() {
			continue
		}
		quoteID, err := newQuoteID()
		if err != nil {
			// No entropy, no probe: the entry simply stays unconfirmed.
			r.logger.Error("capacity probe id generation failed", "provider_id", providerID, "error", err)
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
			r.logger.Error("capacity probe marshal failed", "provider_id", providerID, "error", err)
			continue
		}
		// Register BEFORE sending so a quote racing the sender's return can
		// never miss its entry.
		r.capacityQuotes.add(quoteID, &pendingQuote{
			providerID: providerID,
			expiresAt:  expiresAt,
			deliver:    deliveries,
		})
		outstanding[quoteID] = providerID
		saferun.Go(r.logger, "registry.capacityProbeSend", func() {
			// The write is useless past the quote window — bound it there
			// rather than letting a wedged data lane hold the goroutine.
			ctx, cancel := context.WithTimeout(context.Background(), window)
			defer cancel()
			if writeErr := provider.WriteText(ctx, payload); writeErr != nil {
				// Queue full / writer stopped / timeout: settle as SendFailed
				// now IF this probe is still ours to settle (a disconnect may
				// have claimed it first — take() decides exactly once).
				if pq := r.capacityQuotes.take(quoteID); pq != nil {
					deliveries <- quoteDelivery{quoteID: quoteID, providerID: providerID}
				}
			}
		})
	}
	if len(outstanding) == 0 {
		close(out)
		return out
	}

	saferun.Go(r.logger, "registry.capacityQuoteCollector", func() {
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
					if r.capacityQuotes.take(quoteID) == nil {
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

// applyQuoteDelivery turns a settled probe into its plan mutation + outcome:
// affirmative quote → confirm, everything else → demote. Kept pure of channel
// plumbing so tests pin the mapping directly.
func applyQuoteDelivery(plan *DispatchPlan, d quoteDelivery) QuoteOutcome {
	if d.quote == nil {
		plan.DemoteEntry(d.providerID)
		return QuoteOutcome{ProviderID: d.providerID, SendFailed: true}
	}
	if d.quote.AdmissibleNow {
		plan.ConfirmEntry(d.providerID, d.quote)
	} else {
		plan.DemoteEntry(d.providerID)
	}
	return QuoteOutcome{ProviderID: d.providerID, Quote: d.quote}
}

// HedgeGovernorSnapshot gathers the registry-side inputs the hedge governor
// (api/hedge_governor.go) needs to decide whether launching insurance is
// spending idle capacity or amplifying an overload:
//
//   - idleAlternativeExists: some provider OTHER than the exclusions is an
//     instantly-usable spread target for this request — the same computation
//     as the Phase-0 shadow signal (loadedIdleAlternativeExistsLocked), so
//     the governor and the shadow metric can never disagree on "spare
//     capacity exists";
//   - modelQueueDepth: queued demand for the model (queued consumers outrank
//     insurance);
//   - fleetIdleSlots: slots with any model resident and zero occupancy,
//     across the whole fleet, from the same heartbeat BackendCapacity
//     snapshots routing reads — the global concurrent-hedge budget's
//     denominator;
//   - capacitySignalsAvailable: at least one live provider serving the model
//     reports a BackendCapacity snapshot (or has proven quote capability).
//     The dual-path switch: on a capacity-SILENT fleet (all-legacy, plan
//     decision 3) the three signals above are structurally zero — the same
//     shape as genuine saturation — so the governor must be BYPASSED there
//     (today's unconditional 50% hedge), never consulted. Deliberately looser
//     than the full gate chain: this is an advisory "are the inputs
//     meaningful?" bit, not an eligibility decision — reserve-time
//     revalidation still applies every gate.
//
// This is a POINT-IN-TIME advisory snapshot, not a reservation: the governor
// only ever uses it to SUPPRESS a hedge, and a hedge launched on state that
// staled a moment later is caught by the plan revalidation gates at reserve
// time. Tolerating that staleness is what lets this run under r.mu.RLock
// (plus per-provider p.mu, the standard order) instead of serializing with
// reservations. Queue depth is read before taking r.mu so q.mu never nests
// inside it (see RequestQueue.PreferWaiterOwners for the ordering rule).
func (r *Registry) HedgeGovernorSnapshot(model string, pr *PendingRequest, excludeIDs ...string) (idleAlternativeExists bool, modelQueueDepth int, fleetIdleSlots int, capacitySignalsAvailable bool) {
	if q := r.Queue(); q != nil {
		modelQueueDepth = q.QueueSize(model)
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if pr != nil {
		idleAlternativeExists = r.loadedIdleAlternativeExistsLocked(model, pr, nil, excludeIDs...)
	}
	for _, p := range r.providers {
		p.mu.Lock()
		if p.Status != StatusUntrusted && p.Status != StatusOffline {
			if p.BackendCapacity != nil {
				for _, slot := range p.BackendCapacity.Slots {
					if slotStateModelLoaded(slot.State) && slot.NumRunning == 0 && slot.NumWaiting == 0 {
						fleetIdleSlots++
					}
				}
			}
			// Model-scoped: a reporting provider that cannot serve this model
			// says nothing about whether THIS model's governor inputs are
			// meaningful. The exclusion set is deliberately NOT applied — the
			// primary reporting capacity already proves this is a reporting
			// fleet for the model (dual path is capability-based, not
			// request-sampled).
			if !capacitySignalsAvailable && (p.BackendCapacity != nil || p.capacityQuoteCapable) {
				for _, m := range p.Models {
					if m.ID == model {
						capacitySignalsAvailable = true
						break
					}
				}
			}
		}
		p.mu.Unlock()
	}
	return idleAlternativeExists, modelQueueDepth, fleetIdleSlots, capacitySignalsAvailable
}
