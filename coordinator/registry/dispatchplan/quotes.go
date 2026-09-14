package dispatchplan

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// quoteDelivery is the tracker→collector handoff for one settled probe.
// timeout marks an expiry sweep; otherwise quote == nil means transport failure.
type quoteDelivery struct {
	quoteID    string
	providerID string
	quote      *protocol.CapacityQuoteMessage
	timeout    bool
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

// quoteTrackerSweepInterval is the minimum spacing between full sweeps of the
// pending-quote map. Probe entries expire at probe-window scale (the api
// layer's capacityProbeWindow, 250ms), so sweeping faster than the window is
// pure overhead: entries added since the last sweep cannot have expired yet,
// and rescanning them buys nothing. Without the gate the >1024 size trigger
// turns quadratic under sustained load — at eight probes per request and a
// 250ms window, ~129 concurrent primary requests keep the map above the
// threshold with mostly-unexpired entries, so EVERY insertion would rescan
// the whole map under the single tracker mutex and serialize quote delivery
// behind cleanup (codex P1). One sweep per window bounds cleanup to O(size)
// per window instead of per insert.
const quoteTrackerSweepInterval = 250 * time.Millisecond

// Probes correlates capacity quotes with their probes by quote_id.
// LEAF mutex: nothing is called while holding t.mu except buffered channel
// sends, and no code path takes r.mu, p.mu, or a plan mu under it.
type Probes[C comparable] struct {
	mu      sync.Mutex
	pending map[string]*pendingQuote
	// lastSweep gates add's expiry sweep to once per
	// quoteTrackerSweepInterval; sweeps counts performed sweeps (test
	// instrumentation only). Both guarded by mu.
	lastSweep time.Time
	sweeps    int
}

// add registers an outstanding probe. The opportunistic sweep settles expired
// entries, including when its collector has not yet processed the timer. Every
// removal must deliver an outcome: collectors treat a missing entry as a claim
// whose delivery is in flight. The >1024 size
// trigger merely makes a sweep WORTH considering; the time gate
// (quoteTrackerSweepInterval) decides whether one actually runs.
func (t *Probes[C]) add(quoteID string, pq *pendingQuote) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.pending == nil {
		t.pending = make(map[string]*pendingQuote)
	}
	if len(t.pending) > 1024 {
		now := time.Now()
		if now.Sub(t.lastSweep) >= quoteTrackerSweepInterval {
			t.lastSweep = now
			t.sweeps++
			for id, e := range t.pending {
				if now.After(e.expiresAt) {
					delete(t.pending, id)
					if e.deliver != nil {
						e.deliver <- quoteDelivery{quoteID: id, providerID: e.providerID, timeout: true}
					}
				}
			}
		}
	}
	t.pending[quoteID] = pq
}

// take claims an outstanding probe by quote_id, or nil when another settling
// event already claimed it. The removal IS the exactly-once guarantee.
func (t *Probes[C]) take(quoteID string) *pendingQuote {
	t.mu.Lock()
	defer t.mu.Unlock()
	pq := t.pending[quoteID]
	delete(t.pending, quoteID)
	return pq
}

// FailProvider settles every outstanding probe bound to a disconnected
// provider as a transport failure. Delivering under t.mu is safe (buffered
// channels, one delivery per entry) and keeps claim+delivery atomic.
func (t *Probes[C]) FailProvider(providerID string) {
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

// PendingCount reports outstanding correlations without exposing the map.
func (t *Probes[C]) PendingCount() int { t.mu.Lock(); defer t.mu.Unlock(); return len(t.pending) }
