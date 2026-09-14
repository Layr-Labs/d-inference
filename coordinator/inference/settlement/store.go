package settlement

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store is the financial projection used by reservation and completion paths.
// Atomic balances and durable ledger entries remain the store's responsibility.
type Store interface {
	GetUserByAccountID(accountID string) (*store.User, error)
	GetModelPrice(accountID, model string) (inputPrice, outputPrice int64, ok bool)
	KeySpendSince(keyID string, since time.Time) int64
	Credit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error
	CreditProviderAccount(earning *store.ProviderEarning) error
	RecordUsageFullWithPublicModel(providerID, consumerKey, keyID, model, publicModel, requestID string, promptTokens, completionTokens int, costMicroUSD int64, requestLocation *store.ProviderLocation)
}

type BalanceReader interface {
	GetBalance(accountID string) int64
}
