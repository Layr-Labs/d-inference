package postgres

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

func fenceBillingSession(ctx context.Context, tx pgx.Tx, session *store.BillingSession) (bool, error) {
	externalID := session.ExternalID
	if session.PaymentMethod != "stripe" {
		externalID = ""
	}
	deleted, err := fenceErasureExternalObject(ctx, tx, session.AccountID, store.ErasureTargetCheckoutSessions, externalID)
	if err != nil {
		return false, err
	}
	if deleted {
		session.ExternalID, session.ReferralCode, session.Status = "", "", "erased"
	}
	return deleted, nil
}
