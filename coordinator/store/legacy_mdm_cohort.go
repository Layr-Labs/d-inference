package store

import "context"

// LegacyMDMCohortStore freezes upgrade eligibility explicitly at startup, never
// during migration. Membership is historical eligibility, not current trust.
// Callers using a decorated Store must discover this interface with store.As.
type LegacyMDMCohortStore interface {
	FreezeLegacyMDMCohort(context.Context) ([]LegacyMDMMachine, error)
}

type LegacyMDMMachine struct {
	AccountID    string `json:"account_id"`
	SEPublicKey  string `json:"se_public_key"`
	SerialNumber string `json:"serial_number"`
}
