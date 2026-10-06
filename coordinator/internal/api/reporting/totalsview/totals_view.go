package totalsview

import (
	"sync"

	refresher "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/refresher"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Totals struct {
	*refresher.Service
	store                store.Store
	networkTotalsRefresh struct {
		queryMu sync.Mutex
		mu      sync.Mutex
		entries map[string]*refresher.Entry
	}
}

func New(st store.Store, refresh *refresher.Service) *Totals {
	return &Totals{Service: refresh, store: st}
}

func (s *Totals) CachedNetworkTotals(window string) ([]byte, bool) {
	return s.GetCachedEntry(s.networkTotalsEntry(window), NetworkTotalsCacheKey(window), func() ([]byte, error) { return s.ComputeNetworkTotals(window) })
}
