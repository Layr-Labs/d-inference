package shared

import "github.com/eigeninference/d-inference/coordinator/store"

func CheckoutMatches(s *store.BillingSession, externalID, accountID string, amount int64) bool {
	return s != nil && externalID != "" && accountID != "" && amount > 0 && s.PaymentMethod == "stripe" && s.ExternalID == externalID && s.AccountID == accountID && s.AmountMicroUSD == amount && (s.Status == "pending" || s.Status == "completed")
}
