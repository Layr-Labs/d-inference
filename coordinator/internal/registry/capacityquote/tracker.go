// Package capacityquote correlates capacity probes with exactly-once settlement.
package capacityquote

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Delivery is the tracker-to-collector handoff for one settled probe.
// A nil Quote means transport failure (send error or disconnect).
type Delivery struct {
	QuoteID    string
	ProviderID string
	Quote      *protocol.CapacityQuoteMessage
	ObservedAt time.Time
}

// Pending binds a probe to its provider, expiry, and owning collector.
// Deliver must be buffered to the collector's full probe count: each entry
// delivers at most once, so sends never block while holding the tracker mutex.
type Pending struct {
	ProviderID string
	ExpiresAt  time.Time
	Deliver    chan<- Delivery
}

// Cadence claims an opportunistic expiry sweep while the tracker is locked.
type Cadence interface {
	Claim(now time.Time) bool
}

// Schedule limits full sweeps to once per probe window. The size trigger only
// makes a sweep worth considering; without this gate sustained load above the
// threshold would rescan the whole map on every insertion.
// Its owning tracker serializes access.
type Schedule struct {
	lastSweep time.Time
}

func (s *Schedule) Claim(now time.Time) bool {
	if now.Sub(s.lastSweep) >= 250*time.Millisecond {
		s.lastSweep = now
		return true
	}
	return false
}

// Tracker owns the outstanding probes. Its mutex is a leaf: callbacks and
// buffered deliveries must not acquire registry, provider, or plan locks.
type Tracker struct {
	mu      sync.Mutex
	pending map[string]*Pending
	now     func() time.Time
	cadence Cadence
}

func New(now func() time.Time, cadence Cadence) *Tracker {
	if now == nil {
		now = time.Now
	}
	if cadence == nil {
		cadence = &Schedule{}
	}
	return &Tracker{now: now, cadence: cadence}
}

// Add registers a probe. A sweep also settles expired entries whose live
// collectors have not yet run their timers, so no claimed delivery is lost.
func (t *Tracker) Add(quoteID string, pq *Pending) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.pending == nil {
		t.pending = make(map[string]*Pending)
	}
	if t.lenLocked() > 1024 {
		now := t.now()
		if t.cadence.Claim(now) {
			for id, e := range t.pending {
				if now.After(e.ExpiresAt) {
					delete(t.pending, id)
					if e.Deliver != nil {
						e.Deliver <- Delivery{QuoteID: id, ProviderID: e.ProviderID}
					}
				}
			}
		}
	}
	t.pending[quoteID] = pq
}

func (t *Tracker) lenLocked() int { return len(t.pending) }

// Len reports outstanding correlations, including expired probes not yet
// claimed by a quote, timeout, disconnect, or opportunistic sweep.
func (t *Tracker) Len() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.lenLocked()
}

// Take claims a probe, or returns nil when another event already settled it.
// Removal is the exactly-once guarantee.
func (t *Tracker) Take(quoteID string) *Pending {
	t.mu.Lock()
	defer t.mu.Unlock()
	pq := t.pending[quoteID]
	delete(t.pending, quoteID)
	return pq
}

// Resolve delivers a valid quote and returns a bounded rejection reason otherwise.
// Mismatched and expired quotes remain registered for their rightful owner.
// Nil messages and empty IDs are ignored without a rejection reason.
func (t *Tracker) Resolve(providerID string, msg *protocol.CapacityQuoteMessage) string {
	if msg == nil || msg.QuoteID == "" {
		return ""
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	pq, ok := t.pending[msg.QuoteID]
	if !ok {
		return "unknown_or_late_quote_id"
	}
	if pq.ProviderID != providerID {
		return "provider_mismatch"
	}
	if t.now().After(pq.ExpiresAt) {
		return "expired"
	}
	delete(t.pending, msg.QuoteID)
	pq.Deliver <- Delivery{QuoteID: msg.QuoteID, ProviderID: providerID, Quote: msg, ObservedAt: t.now()}
	return ""
}

// FailProvider atomically claims and delivers all probes bound to a disconnected
// provider as transport failures.
func (t *Tracker) FailProvider(providerID string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for id, pq := range t.pending {
		if pq.ProviderID != providerID {
			continue
		}
		delete(t.pending, id)
		pq.Deliver <- Delivery{QuoteID: id, ProviderID: providerID}
	}
}
