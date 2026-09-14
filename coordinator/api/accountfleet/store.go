package accountfleet

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store reads account earnings and provider records, and removes only records
// belonging to the supplied account. Financial history remains store-owned.
type Store interface {
	GetAccountEarningsSummary(string) (store.ProviderEarningsSummary, error)
	AccountEarningsWindows(string, time.Time) (store.AccountEarningsWindows, error)
	GetBalance(string) int64
	GetWithdrawableBalance(string) int64
	ListProvidersByAccount(context.Context, string) ([]store.ProviderRecord, error)
	GetReputations(context.Context, []string) (map[string]*store.ReputationRecord, error)
	GetProviderRecord(context.Context, string) (*store.ProviderRecord, error)
	DeleteProvidersBySerial(context.Context, string, string) (int, error)
}
