package api

import (
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// accountEarningsSummary treats a genuinely empty account as a zero-valued
// summary while preserving operational store errors. Keeping this translation
// at the API boundary prevents database failures from masquerading as zero
// lifetime earnings.
func (s *Server) accountEarningsSummary(accountID string) (store.ProviderEarningsSummary, error) {
	summary, err := s.store.GetAccountEarningsSummary(accountID)
	if errors.Is(err, store.ErrNotFound) {
		return store.ProviderEarningsSummary{}, nil
	}
	return summary, err
}
