package billing

import "github.com/eigeninference/d-inference/coordinator/store"

// Store is the account/pricing/earnings view used directly by these endpoints.
// Checkout and payout transitions use the current billing service's store, so
// its existing transaction, locking and optional Global Payouts contracts stay
// with that service rather than being reimplemented by the HTTP controller.
type Store interface {
	ListModelPrices(accountID string) []store.ModelPrice
	SetModelPrice(accountID, model string, inputPrice, outputPrice int64) error
	DeleteModelPrice(accountID, model string) error
	SetUserRole(accountID, role string) error
	SetUserPlatformFeePercent(accountID string, feePercent *int64) error
	GetUserByEmail(email string) (*store.User, error)
	Credit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error
	CreditWithdrawable(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error
	GetBalance(accountID string) int64
	GetWithdrawableBalance(accountID string) int64
	GetBalanceWithWithdrawable(accountID string) (balance int64, withdrawable int64)
	GetAccountEarnings(accountID string, limit int) ([]store.ProviderEarning, error)
	GetAccountEarningsSummary(accountID string) (store.ProviderEarningsSummary, error)
}
