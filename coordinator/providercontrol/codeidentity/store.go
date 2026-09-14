package codeidentity

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type CoverageStore interface {
	AdvanceCodeAttestationCoverage(context.Context, []store.CodeAttestation) error
}

// Store is the minimal slice of store.Store the code-identity reuse
// cache needs to survive coordinator restarts/blue-green deploys.
// store.Store satisfies it; tests can inject a fake. SECURITY: persistence is a
// performance optimization (avoid re-pushing within the reuse window), not an
// unconditional grant. reuseAttestation re-applies version, freshness, current
// token, and exact registration process-key gates to every seeded row.
type Store interface {
	ListCodeAttestations(ctx context.Context) ([]store.CodeAttestation, error)
	UpsertCodeAttestation(ctx context.Context, rec store.CodeAttestation) error
	DeleteCodeAttestation(ctx context.Context, seKey string) error
}

type pushBudgetStore interface {
	ListCodeAttestPushBudgets(ctx context.Context) ([]store.CodeAttestPushBudget, error)
	ReserveCodeAttestPushBudget(
		ctx context.Context,
		seKey, tokenHash string,
		now, nextPushAt time.Time,
	) (bool, error)
	ClearCodeAttestPushFloor(
		ctx context.Context,
		seKey string,
		now time.Time,
		cooldown time.Duration,
	) (time.Time, bool, error)
}
