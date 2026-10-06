package postgres

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/consumersettlement"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

func settlementReferrer(ctx context.Context, tx pgx.Tx, consumer string) (string, error) {
	var referrer string
	err := tx.QueryRow(ctx, `SELECT r.account_id FROM referrals f JOIN referrers r ON r.code=f.referrer_code WHERE f.referred_account=$1 AND r.account_id<>$1`, consumer).Scan(&referrer)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return referrer, err
}

func recordPromotionReferral(ctx context.Context, tx pgx.Tx, r store.ModelTokenReservation, referrer string, referralEligible bool) error {
	record := consumersettlement.PromotionRecord(r, referrer, referralEligible)
	if reward := record.Result.ReferralRewardMicroUSD; reward > 0 {
		if err := creditWithdrawableBalance(ctx, tx, referrer, reward, store.LedgerReferralReward, record.Input.JobID, time.Time{}); err != nil {
			return err
		}
	}
	_, err := tx.Exec(ctx, `INSERT INTO consumer_charge_settlements
		(job_id,account_id,reserved_micro_usd,requested_micro_usd,referral_enabled,collected_micro_usd,referrer_account,reward_micro_usd,uncollected)
		VALUES ($1,$2,$3,$4,$7,$4,$5,$6,false)`, record.Input.JobID, r.AccountID, r.ReservedMicroUSD, r.ConsumerCostMicroUSD, record.Referrer, record.Result.ReferralRewardMicroUSD, referralEligible)
	return err
}
