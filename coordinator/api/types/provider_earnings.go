package types

import "github.com/eigeninference/d-inference/coordinator/store"

// AccountEarningsProvider maps an ephemeral provider encryption key/session
// back to the physical Mac that produced it. The response is account-authenticated.
type AccountEarningsProvider struct {
	ProviderID   string `json:"provider_id"`
	ProviderKey  string `json:"provider_key"`
	SerialNumber string `json:"serial_number"`
}

// AccountEarningsResponse is the authenticated linked-provider earnings
// contract consumed by the provider CLI, native app, and console.
type AccountEarningsResponse struct {
	AccountID                   string                    `json:"account_id"`
	Earnings                    []store.ProviderEarning   `json:"earnings"`
	Providers                   []AccountEarningsProvider `json:"providers"`
	TotalMicroUSD               int64                     `json:"total_micro_usd"`
	TotalUSD                    string                    `json:"total_usd"`
	Count                       int64                     `json:"count"`
	RecentCount                 int                       `json:"recent_count"`
	HistoryLimit                int                       `json:"history_limit"`
	AvailableBalanceMicroUSD    int64                     `json:"available_balance_micro_usd"`
	AvailableBalanceUSD         string                    `json:"available_balance_usd"`
	WithdrawableBalanceMicroUSD int64                     `json:"withdrawable_balance_micro_usd"`
	WithdrawableBalanceUSD      string                    `json:"withdrawable_balance_usd"`
}
