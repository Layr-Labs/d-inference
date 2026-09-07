package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

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

// FinalizeConsumerCharge makes the collected amount, refund/overage, referrer
// attribution, and withdrawable reward a single durable transaction. The job
// key serializes retries, including an uncertain COMMIT response. A failed
// transaction leaves the existing preflight reservation available for refund.
func (s *PostgresStore) FinalizeConsumerCharge(in ConsumerChargeSettlement) (ConsumerChargeResult, error) {
	if err := validateConsumerSettlement(in); err != nil {
		return ConsumerChargeResult{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return ConsumerChargeResult{}, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "consumer-settlement:"+in.JobID); err != nil {
		return ConsumerChargeResult{}, err
	}
	var old consumerSettlementRecord
	old.Input.JobID = in.JobID
	err = tx.QueryRow(ctx, `SELECT account_id, reserved_micro_usd, requested_micro_usd, referral_enabled,
		collected_micro_usd, referrer_account, reward_micro_usd, uncollected
		FROM consumer_charge_settlements WHERE job_id=$1`, in.JobID).Scan(
		&old.Input.AccountID, &old.Input.ReservedMicroUSD, &old.Input.CostMicroUSD, &old.Input.ReferralEnabled,
		&old.Result.CollectedMicroUSD, &old.Referrer, &old.Result.ReferralRewardMicroUSD, &old.Result.Uncollected)
	if err == nil {
		return replayConsumerSettlement(in, old)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return ConsumerChargeResult{}, fmt.Errorf("store: read consumer settlement: %w", err)
	}
	referrer := ""
	if in.ReferralEnabled {
		err = tx.QueryRow(ctx, `SELECT r.account_id FROM referrals f JOIN referrers r ON r.code=f.referrer_code
			WHERE f.referred_account=$1 AND r.account_id<>$1`, in.AccountID).Scan(&referrer)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return ConsumerChargeResult{}, fmt.Errorf("store: lookup settlement referral: %w", err)
		}
	}
	// Lock both balances in deterministic order. Reciprocal referrals and a
	// referrer spending their own earnings must not deadlock at concurrent
	// consumer/referrer credit updates.
	accounts := []string{in.AccountID}
	if referrer != "" {
		accounts = append(accounts, referrer)
	}
	sort.Strings(accounts)
	var consumerBalance int64
	for _, account := range accounts {
		if _, err := tx.Exec(ctx, `INSERT INTO balances (account_id,balance_micro_usd) VALUES ($1,0) ON CONFLICT DO NOTHING`, account); err != nil {
			return ConsumerChargeResult{}, err
		}
		var balance int64
		if err := tx.QueryRow(ctx, `SELECT balance_micro_usd FROM balances WHERE account_id=$1 FOR UPDATE`, account).Scan(&balance); err != nil {
			return ConsumerChargeResult{}, err
		}
		if account == in.AccountID {
			consumerBalance = balance
		}
	}
	collected, uncollected := settlementCost(in, consumerBalance)
	delta := collected - in.ReservedMicroUSD
	if delta < 0 {
		if err := creditBalance(ctx, tx, in.AccountID, -delta, LedgerRefund, in.JobID, time.Time{}); err != nil {
			return ConsumerChargeResult{}, err
		}
	} else if delta > 0 {
		reference := in.JobID
		if in.ReservedMicroUSD > 0 {
			reference = "overage:" + in.JobID
		}
		if _, err := tx.Exec(ctx, `WITH debit AS (
			UPDATE balances SET balance_micro_usd=balance_micro_usd-$2,
			withdrawable_micro_usd=LEAST(withdrawable_micro_usd,balance_micro_usd-$2),updated_at=NOW()
			WHERE account_id=$1 RETURNING balance_micro_usd)
			INSERT INTO ledger_entries (account_id,entry_type,amount_micro_usd,balance_after,reference)
			SELECT $1,$3,-$2,balance_micro_usd,$4 FROM debit`, in.AccountID, delta, string(LedgerCharge), reference); err != nil {
			return ConsumerChargeResult{}, err
		}
	}
	reward := int64(0)
	if referrer != "" {
		reward = collected / (100 / ConsumerReferralPercent)
	}
	if reward > 0 {
		if err := creditWithdrawableBalance(ctx, tx, referrer, reward, LedgerReferralReward, in.JobID, time.Time{}); err != nil {
			return ConsumerChargeResult{}, err
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO consumer_charge_settlements
		(job_id,account_id,reserved_micro_usd,requested_micro_usd,referral_enabled,collected_micro_usd,referrer_account,reward_micro_usd,uncollected)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`, in.JobID, in.AccountID, in.ReservedMicroUSD,
		in.CostMicroUSD, in.ReferralEnabled, collected, referrer, reward, uncollected); err != nil {
		return ConsumerChargeResult{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return ConsumerChargeResult{}, err
	}
	return ConsumerChargeResult{CollectedMicroUSD: collected, ReferralRewardMicroUSD: reward, Applied: true, Uncollected: uncollected}, nil
}
