package api

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

// mySummaryWindowsCacheTTL matches the dashboard's poll interval, so an
// account with several open tabs computes its rolling windows once per poll.
const mySummaryWindowsCacheTTL = 15 * time.Second

// accountEarningsWindows returns the account's rolling-window earnings from a
// per-account read-cache entry, computing them in the store on a miss. The
// aggregate replaces a 5,000-row page summed in Go, which truncated the 7 d
// figures for any account with more rows than that.
func (s *Server) accountEarningsWindows(accountID string) (store.AccountEarningsWindows, error) {
	key := "me:summary:windows:" + accountID
	if s.readCache != nil {
		if cached, ok := s.readCache.Get(key); ok {
			var w store.AccountEarningsWindows
			if err := json.Unmarshal(cached, &w); err == nil {
				return w, nil
			}
		}
	}
	w, err := s.store.AccountEarningsWindows(accountID, time.Now())
	if err != nil {
		return store.AccountEarningsWindows{}, err
	}
	if s.readCache != nil {
		if body, err := json.Marshal(w); err == nil {
			s.readCache.Set(key, body, mySummaryWindowsCacheTTL)
		}
	}
	return w, nil
}
