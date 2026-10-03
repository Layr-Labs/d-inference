package accounts

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *blockingDashboardStore) AccountEarningsWindows(account string, now time.Time) (store.AccountEarningsWindows, error) {
	s.calls.Add(1)
	s.entered <- account
	<-s.release
	return s.Store.AccountEarningsWindows(account, now)
}

func (c *countingMeStore) AccountEarningsWindows(accountID string, now time.Time) (store.AccountEarningsWindows, error) {
	c.windows.Add(1)
	return c.Store.AccountEarningsWindows(accountID, now)
}

func (c *countingMeStore) ListProvidersByAccount(ctx context.Context, accountID string) ([]store.ProviderRecord, error) {
	c.listProviders.Add(1)
	return c.Store.ListProvidersByAccount(ctx, accountID)
}

func (c *countingMeStore) GetReputation(ctx context.Context, providerID string) (*store.ReputationRecord, error) {
	c.getReputation.Add(1)
	return c.Store.GetReputation(ctx, providerID)
}

func (c *countingMeStore) GetReputations(ctx context.Context, ids []string) (map[string]*store.ReputationRecord, error) {
	c.getReputBatch.Add(1)
	return c.Store.GetReputations(ctx, ids)
}
