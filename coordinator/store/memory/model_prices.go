package memory

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) SetModelPrice(price store.ModelPrice) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.modelPrices[price.AccountID+":"+price.Model] = price.Clone()
	return nil
}

func (s *MemoryStore) GetModelPrice(accountID, model string) (store.ModelPrice, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	mp, ok := s.modelPrices[accountID+":"+model]
	if !ok {
		return store.ModelPrice{}, false
	}
	return mp.Clone(), true
}

func (s *MemoryStore) ListModelPrices(accountID string) []store.ModelPrice {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var prices []store.ModelPrice
	for _, mp := range s.modelPrices {
		if mp.AccountID == accountID {
			prices = append(prices, mp.Clone())
		}
	}
	return prices
}

func (s *MemoryStore) DeleteModelPrice(accountID, model string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	key := accountID + ":" + model
	if _, ok := s.modelPrices[key]; !ok {
		return fmt.Errorf("no custom price for model %q", model)
	}
	delete(s.modelPrices, key)
	return nil
}
