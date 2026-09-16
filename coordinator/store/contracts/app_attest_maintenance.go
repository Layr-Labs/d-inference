package contracts

import (
	"context"
	"time"
)

// Reconciliation never replays a signature into a live credential counter or
// rewrites a rejection as an acceptance. New live challenges recover trust.
type AppAttestMaintenanceStore interface {
	ReconcileAppAttestEvidence(context.Context, time.Time, int) (int64, error)
	QueueAppAttestReceiptRecovery(context.Context, int) (int64, error)
}
