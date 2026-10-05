package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/consumersettlement"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
)

const consumerSettlementSchema = `CREATE TABLE IF NOT EXISTS consumer_charge_settlements (
	job_id TEXT PRIMARY KEY,
	account_id TEXT NOT NULL,
	reserved_micro_usd BIGINT NOT NULL CHECK (reserved_micro_usd >= 0),
	requested_micro_usd BIGINT NOT NULL CHECK (requested_micro_usd >= 0),
	referral_enabled BOOLEAN NOT NULL,
	collected_micro_usd BIGINT NOT NULL CHECK (collected_micro_usd >= 0),
	referrer_account TEXT NOT NULL DEFAULT '',
	reward_micro_usd BIGINT NOT NULL CHECK (reward_micro_usd >= 0),
	uncollected BOOLEAN NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
)`

// FinalizeConsumerCharge commits the collected amount, refund/overage, referral
// attribution, and withdrawable reward together. The job key serializes retries,
// including an uncertain COMMIT response. Failure leaves the reservation intact.
func (s *PostgresStore) FinalizeConsumerCharge(in store.ConsumerChargeSettlement) (store.ConsumerChargeResult, error) {
	if err := consumersettlement.Validate(in); err != nil {
		return store.ConsumerChargeResult{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return store.ConsumerChargeResult{}, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "consumer-settlement:"+in.JobID); err != nil {
		return store.ConsumerChargeResult{}, err
	}
	var old consumersettlement.Record
	old.Input.JobID = in.JobID
	err = tx.QueryRow(ctx, `SELECT account_id, reserved_micro_usd, requested_micro_usd, referral_enabled,
		collected_micro_usd, referrer_account, reward_micro_usd, uncollected
		FROM consumer_charge_settlements WHERE job_id=$1`, in.JobID).Scan(
		&old.Input.AccountID, &old.Input.ReservedMicroUSD, &old.Input.CostMicroUSD, &old.Input.ReferralEnabled,
		&old.Result.CollectedMicroUSD, &old.Referrer, &old.Result.ReferralRewardMicroUSD, &old.Result.Uncollected)
	if err == nil {
		return consumersettlement.Replay(in, old)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return store.ConsumerChargeResult{}, fmt.Errorf("store: read consumer settlement: %w", err)
	}
	referrer := ""
	if in.ReferralEnabled {
		referrer, err = settlementReferrer(ctx, tx, in.AccountID)
		if err != nil {
			return store.ConsumerChargeResult{}, fmt.Errorf("store: lookup settlement referral: %w", err)
		}
	}
	accounts := []string{in.AccountID}
	if referrer != "" {
		accounts = append(accounts, referrer)
	}
	if err := lockSettlementBalances(ctx, tx, accounts); err != nil {
		return store.ConsumerChargeResult{}, err
	}
	var consumerBalance int64
	if err := tx.QueryRow(ctx, `SELECT balance_micro_usd FROM balances WHERE account_id=$1`, in.AccountID).Scan(&consumerBalance); err != nil {
		return store.ConsumerChargeResult{}, err
	}
	collected, uncollected := consumersettlement.Cost(in, consumerBalance)
	delta := collected - in.ReservedMicroUSD
	if delta < 0 {
		if err := creditBalance(ctx, tx, in.AccountID, -delta, store.LedgerRefund, in.JobID, time.Time{}); err != nil {
			return store.ConsumerChargeResult{}, err
		}
	} else if delta > 0 {
		reference := in.JobID
		if in.ReservedMicroUSD > 0 {
			reference = "overage:" + in.JobID
		}
		if err := debitBalance(ctx, tx, in.AccountID, delta, store.LedgerCharge, reference); err != nil {
			return store.ConsumerChargeResult{}, err
		}
	}
	reward := int64(0)
	if referrer != "" {
		reward = collected / (100 / store.ConsumerReferralPercent)
	}
	if reward > 0 {
		if err := creditWithdrawableBalance(ctx, tx, referrer, reward, store.LedgerReferralReward, in.JobID, time.Time{}); err != nil {
			return store.ConsumerChargeResult{}, err
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO consumer_charge_settlements
		(job_id,account_id,reserved_micro_usd,requested_micro_usd,referral_enabled,collected_micro_usd,referrer_account,reward_micro_usd,uncollected)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`, in.JobID, in.AccountID, in.ReservedMicroUSD,
		in.CostMicroUSD, in.ReferralEnabled, collected, referrer, reward, uncollected); err != nil {
		return store.ConsumerChargeResult{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return store.ConsumerChargeResult{}, err
	}
	return store.ConsumerChargeResult{CollectedMicroUSD: collected, ReferralRewardMicroUSD: reward, Applied: true, Uncollected: uncollected}, nil
}
