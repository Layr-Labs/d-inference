package settlement

import (
	"sync"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type ServiceHolds struct {
	store   BalanceReader
	enabled bool

	mu          sync.Mutex
	outstanding map[string]int64
}

func NewServiceHolds(st BalanceReader, enabled bool) *ServiceHolds {
	return &ServiceHolds{store: st, enabled: enabled, outstanding: make(map[string]int64)}
}

func (m *ServiceHolds) Enabled() bool {
	return m != nil && m.enabled
}

func (m *ServiceHolds) Reserve(accountID string, amount int64) error {
	if m == nil || !m.enabled || amount <= 0 {
		return nil
	}
	balance := m.store.GetBalance(accountID)

	m.mu.Lock()
	defer m.mu.Unlock()
	if balance-m.outstanding[accountID] < amount {
		return store.ErrInsufficientBalance
	}
	m.outstanding[accountID] += amount
	return nil
}

func (m *ServiceHolds) Release(accountID string, amount int64) {
	if m == nil || !m.enabled || amount <= 0 {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	current := m.outstanding[accountID]
	if amount >= current {
		delete(m.outstanding, accountID)
		return
	}
	m.outstanding[accountID] = current - amount
}
