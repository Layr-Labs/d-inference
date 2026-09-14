package memory

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) SetModelPrice(accountID, model string, inputPrice, outputPrice int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := accountID + ":" + model
	s.modelPrices[key] = contracts.ModelPrice{
		AccountID:   accountID,
		Model:       model,
		InputPrice:  inputPrice,
		OutputPrice: outputPrice,
	}
	return nil
}

func (s *Store) GetModelPrice(accountID, model string) (int64, int64, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	mp, ok := s.modelPrices[accountID+":"+model]
	if !ok {
		return 0, 0, false
	}
	return mp.InputPrice, mp.OutputPrice, true
}

func (s *Store) ListModelPrices(accountID string) []contracts.ModelPrice {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var prices []contracts.ModelPrice
	for _, mp := range s.modelPrices {
		if mp.AccountID == accountID {
			prices = append(prices, mp)
		}
	}
	return prices
}

func (s *Store) DeleteModelPrice(accountID, model string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := accountID + ":" + model
	if _, ok := s.modelPrices[key]; !ok {
		return fmt.Errorf("no custom price for model %q", model)
	}
	delete(s.modelPrices, key)
	return nil
}
