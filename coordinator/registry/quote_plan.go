package registry

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/shortlist"
)

// QuoteCandidate carries only retained identity and immutable ranking evidence.
// A quote never grants admission; the dispatch owner revalidates the binding.
type QuoteCandidate struct {
	PlanEntry
	EvidenceQualified         bool
	ForecastAt                time.Time
	CacheEvidenceWeight       float64
	CacheEstimatedTTFTSavedMs float64
	CacheAffinityEligible     bool
}

type planEntry = QuoteCandidate

// QuotePlan owns the bounded alternate order and quote evidence. DispatchPlan
// embeds this owner, sharing its leaf mutex with reservation and refresh state.
type QuotePlan struct {
	mu            sync.Mutex
	affinity      string
	entries       []QuoteCandidate
	order         shortlist.Order
	retainedOrder *shortlist.Order
}

// NewQuotePlan takes ownership of candidates in their initial ranked order.
// It does not inspect live provider state or reserve any capacity.
func NewQuotePlan(candidates []QuoteCandidate, affinity string, order *shortlist.Order) *QuotePlan {
	p := &QuotePlan{entries: candidates, affinity: affinity, retainedOrder: order}
	for i, entry := range candidates {
		p.alternates().Add(entry.ProviderID, i)
	}
	return p
}

func (p *QuotePlan) alternates() *shortlist.Order {
	if p.retainedOrder != nil {
		return p.retainedOrder
	}
	return &p.order
}
