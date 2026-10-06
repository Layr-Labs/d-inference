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
	if !deleted && session.ReferralCode != "" {
		if err := lockPersonalDataWrite(ctx, tx); err != nil {
			return false, err
		}
		// The payer and referrer can be different accounts. Re-read the
		// captured identity under the scrub fence, never the old code's new owner.
		var code string
		err := tx.QueryRow(ctx, `SELECT code FROM referrers r
 WHERE (($1<>'' AND r.account_id=$1) OR ($1='' AND r.code=$2))
 AND NOT EXISTS(SELECT 1 FROM erasure_requests e WHERE e.account_id=r.account_id AND e.state='erased')`, session.ReferrerAccountID, session.ReferralCode).Scan(&code)
		if noRows(err) {
			session.ReferralCode = ""
		} else if err != nil {
			return false, err
		} else {
			session.ReferralCode = code
		}
	}
	session.ReferrerAccountID = ""
	return deleted, nil
}
