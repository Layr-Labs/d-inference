package api

import (
	"encoding/json"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

const mySummaryWindowsCacheTTL = 15 * time.Second

// accountEarningsWindows coalesces concurrent misses per account. The flight
// group forgets completed calls, so inactive account IDs do not accumulate.
func (s *Server) accountEarningsWindows(accountID string) (store.AccountEarningsWindows, error) {
	key := "me:summary:windows:" + accountID
	cached := func() (store.AccountEarningsWindows, bool) {
		var windows store.AccountEarningsWindows
		if s.readCache != nil {
			if body, ok := s.readCache.Get(key); ok && json.Unmarshal(body, &windows) == nil {
				return windows, true
			}
		}
		return windows, false
	}
	if windows, ok := cached(); ok {
		return windows, nil
	}
	value, err, _ := s.summaryWindowsFlights.Do(key, func() (any, error) {
		// Another fill may have completed after this caller observed its miss.
		if windows, ok := cached(); ok {
			return windows, nil
		}
		windows, err := s.store.AccountEarningsWindows(accountID, time.Now())
		if err != nil {
			return nil, err
		}
		if s.readCache != nil {
			body, err := json.Marshal(windows)
			if err != nil {
				return nil, err
			}
			s.readCache.Set(key, body, mySummaryWindowsCacheTTL)
		}
		return windows, nil
	})
	if err != nil {
		return store.AccountEarningsWindows{}, err
	}
	return value.(store.AccountEarningsWindows), nil
}
