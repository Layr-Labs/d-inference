package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) RecordInferenceSettlementReview(
	settlement *InferenceSettlement,
	reason string,
) (InferenceSettlementDisposition, error) {
	if err := s.ensureOwnership(); err != nil {
		return "", err
	}
	if settlement == nil || settlement.ReservationID == "" ||
		settlement.RequestID == "" || reason == "" {
		return "", ErrFinancialOperationConflict
	}
	payload, err := json.Marshal(settlement)
	if err != nil {
		return "", fmt.Errorf("store: encode settlement review: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", fmt.Errorf("store: begin settlement review: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return "", err
	}
	if err := lockFinancialOperation(ctx, tx, "finalize:"+settlement.ReservationID); err != nil {
		return "", err
	}
	existing, found, err := inferenceSettlementTx(ctx, tx, settlement.ReservationID)
	if err != nil {
		return "", err
	}
	if found {
		if !persistedSettlementMatches(existing, settlement) {
			return "", ErrFinancialOperationConflict
		}
		if err := tx.Commit(ctx); err != nil {
			return "", fmt.Errorf("store: commit reviewed settlement replay: %v: %w", err, ErrCommitOutcomeUnknown)
		}
		return InferenceSettlementReplayed, nil
	}
	if _, released, err := reservationOperationTx(
		ctx, tx, "finalize:"+settlement.ReservationID,
	); err != nil {
		return "", err
	} else if released {
		if err := tx.Commit(ctx); err != nil {
			return "", fmt.Errorf("store: commit reviewed release replay: %v: %w", err, ErrCommitOutcomeUnknown)
		}
		return InferenceSettlementAlreadyReleased, nil
	}
	tag, err := tx.Exec(ctx,
		`INSERT INTO inference_settlement_reviews
			(reservation_id, request_id, reason, payload)
		 VALUES ($1, $2, $3, $4)
		 ON CONFLICT (reservation_id) DO UPDATE SET
			reason = EXCLUDED.reason,
			payload = EXCLUDED.payload,
			updated_at = NOW()
		 WHERE inference_settlement_reviews.request_id = EXCLUDED.request_id`,
		settlement.ReservationID, settlement.RequestID, reason, payload,
	)
	if err != nil {
		return "", fmt.Errorf("store: record settlement review: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return "", ErrFinancialOperationConflict
	}
	if err := tx.Commit(ctx); err != nil {
		return "", fmt.Errorf("store: commit settlement review: %v: %w", err, ErrCommitOutcomeUnknown)
	}
	return InferenceSettlementReviewPending, nil
}

type persistedInferenceSettlement struct {
	requestID                    string
	consumerAccountID            string
	reservedMicroUSD             int64
	reservedWithdrawableMicroUSD int64
	reservationPreDebited        bool
	costMicroUSD                 int64
	providerAccountID            string
	providerID                   string
	providerKey                  string
	providerPayoutMicroUSD       int64
	platformFeeMicroUSD          int64
	referrerAccountID            string
	referralRewardMicroUSD       int64
	model                        string
	publicModel                  string
	keyID                        string
	promptTokens                 int
	completionTokens             int
	recordUsage                  bool
}

func (s *PostgresStore) SettleInference(settlement *InferenceSettlement) (InferenceSettlementDisposition, error) {
	if err := s.ensureOwnership(); err != nil {
		return "", err
	}
	if err := validateInferenceSettlement(settlement); err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", fmt.Errorf("store: begin inference settlement: %w", err)
	}
	defer tx.Rollback(ctx)
	if err := s.verifyOwnershipTx(ctx, tx); err != nil {
		return "", err
	}
	finalizationKey := "finalize:" + settlement.ReservationID
	if err := lockFinancialOperation(ctx, tx, finalizationKey); err != nil {
		return "", err
	}
	existing, found, err := inferenceSettlementTx(ctx, tx, settlement.ReservationID)
	if err != nil {
		return "", err
	}
	if found {
		if !persistedSettlementMatches(existing, settlement) {
			return "", ErrFinancialOperationConflict
		}
		if err := tx.Commit(ctx); err != nil {
			return "", fmt.Errorf("store: commit inference settlement replay: %w", err)
		}
		return InferenceSettlementReplayed, nil
	}
	var reviewedRequestID string
	err = tx.QueryRow(ctx,
		`SELECT request_id FROM inference_settlement_reviews WHERE reservation_id = $1`,
		settlement.ReservationID,
	).Scan(&reviewedRequestID)
	if err == nil {
		if reviewedRequestID != settlement.RequestID {
			return "", ErrFinancialOperationConflict
		}
		if err := tx.Commit(ctx); err != nil {
			return "", fmt.Errorf("store: commit review-pending replay: %v: %w", err, ErrCommitOutcomeUnknown)
		}
		return InferenceSettlementReviewPending, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("store: read settlement review: %w", err)
	}
	if _, finalized, err := reservationOperationTx(ctx, tx, finalizationKey); err != nil {
		return "", err
	} else if finalized {
		if err := tx.Commit(ctx); err != nil {
			return "", fmt.Errorf("store: commit late terminal disposition: %w", err)
		}
		return InferenceSettlementAlreadyReleased, nil
	}
	if settlement.ReservationPreDebited {
		accountID, total, withdrawable, found, err := reservationFundingTx(
			ctx, tx, settlement.ReservationID,
		)
		if err != nil {
			return "", err
		}
		if !found || accountID != settlement.ConsumerAccountID ||
			total != settlement.ReservedMicroUSD ||
			withdrawable != settlement.ReservedWithdrawableMicroUSD {
			return "", ErrFinancialOperationConflict
		}
	}

	refund, refundWithdrawable := int64(0), int64(0)
	if settlement.ReservationPreDebited {
		refund = settlement.ReservedMicroUSD - settlement.CostMicroUSD
		refundWithdrawable = min(refund, settlement.ReservedWithdrawableMicroUSD)
	}
	if err := lockSettlementAccounts(ctx, tx, settlement); err != nil {
		return "", err
	}
	if !settlement.ReservationPreDebited && settlement.CostMicroUSD > 0 {
		var balanceAfter int64
		err := tx.QueryRow(ctx,
			`UPDATE balances SET
				balance_micro_usd = balance_micro_usd - $2,
				withdrawable_micro_usd = LEAST(withdrawable_micro_usd, balance_micro_usd - $2),
				updated_at = NOW()
			 WHERE account_id = $1 AND balance_micro_usd >= $2
			 RETURNING balance_micro_usd`,
			settlement.ConsumerAccountID, settlement.CostMicroUSD,
		).Scan(&balanceAfter)
		if errors.Is(err, pgx.ErrNoRows) {
			return "", ErrInsufficientBalance
		}
		if err != nil {
			return "", fmt.Errorf("store: debit service settlement: %w", err)
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO ledger_entries
				(account_id, entry_type, amount_micro_usd, balance_after, reference)
			 VALUES ($1, $2, $3, $4, $5)`,
			settlement.ConsumerAccountID, string(LedgerCharge),
			-settlement.CostMicroUSD, balanceAfter, settlement.RequestID,
		); err != nil {
			return "", fmt.Errorf("store: record service settlement debit: %w", err)
		}
	}
	if refund > 0 {
		if err := creditBalanceTx(
			ctx, tx, settlement.ConsumerAccountID, refund, refundWithdrawable,
			LedgerRefund, settlement.RequestID,
		); err != nil {
			return "", err
		}
	}
	if earning := settlement.ProviderEarning; earning != nil && earning.AmountMicroUSD > 0 {
		if err := creditBalanceTx(
			ctx, tx, earning.AccountID, earning.AmountMicroUSD, earning.AmountMicroUSD,
			LedgerPayout, settlement.RequestID,
		); err != nil {
			return "", err
		}
		createdAt := earning.CreatedAt
		if createdAt.IsZero() {
			createdAt = time.Now()
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO provider_earnings
				(account_id, provider_id, provider_key, job_id, model, amount_micro_usd,
				 prompt_tokens, completion_tokens, created_at)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
			earning.AccountID, earning.ProviderID, earning.ProviderKey, earning.JobID,
			earning.Model, earning.AmountMicroUSD, earning.PromptTokens,
			earning.CompletionTokens, createdAt,
		); err != nil {
			return "", fmt.Errorf("store: insert provider settlement earning: %w", err)
		}
		if err := updateEarningSummaryTx(ctx, tx, earning.AccountID, "account", earning); err != nil {
			return "", err
		}
		if earning.ProviderKey != "" {
			if err := updateEarningSummaryTx(ctx, tx, earning.ProviderKey, "provider", earning); err != nil {
				return "", err
			}
		}
	}
	if settlement.PlatformFeeMicroUSD > 0 {
		if err := creditBalanceTx(
			ctx, tx, "platform", settlement.PlatformFeeMicroUSD, 0,
			LedgerPlatformFee, settlement.RequestID,
		); err != nil {
			return "", err
		}
	}
	if settlement.ReferralRewardMicroUSD > 0 {
		if err := creditBalanceTx(
			ctx, tx, settlement.ReferrerAccountID, settlement.ReferralRewardMicroUSD,
			settlement.ReferralRewardMicroUSD, LedgerReferralReward, settlement.RequestID,
		); err != nil {
			return "", err
		}
	}
	if settlement.Usage != nil {
		usage := settlement.Usage
		if _, err := tx.Exec(ctx,
			`INSERT INTO usage
				(provider_id, consumer_key_hash, key_id, model, public_model,
				 prompt_tokens, completion_tokens, request_id, cost_micro_usd, request_location)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
			usage.ProviderID, hashKey(usage.ConsumerKey), usage.KeyID, usage.Model,
			usage.PublicModel, usage.PromptTokens, usage.CompletionTokens,
			usage.RequestID, usage.CostMicroUSD, marshalProviderLocation(usage.RequestLocation),
		); err != nil {
			return "", fmt.Errorf("store: insert settlement usage: %w", err)
		}
		if _, err := tx.Exec(ctx,
			`UPDATE usage_totals SET
				total_requests = total_requests + 1,
				total_prompt_tokens = total_prompt_tokens + $1,
				total_completion_tokens = total_completion_tokens + $2
			 WHERE id = 1`,
			usage.PromptTokens, usage.CompletionTokens,
		); err != nil {
			return "", fmt.Errorf("store: update settlement usage totals: %w", err)
		}
	}
	if err := insertReservationOperationTx(ctx, tx, finalizationKey, persistedReservationOperation{
		accountID: settlement.ConsumerAccountID, kind: "release",
		amountMicroUSD: refund, withdrawableMicroUSD: refundWithdrawable,
	}); err != nil {
		return "", err
	}
	if err := insertInferenceSettlementTx(ctx, tx, settlement); err != nil {
		return "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", fmt.Errorf("store: commit inference settlement: %w", err)
	}
	return InferenceSettlementApplied, nil
}

func lockSettlementAccounts(ctx context.Context, tx pgx.Tx, settlement *InferenceSettlement) error {
	accounts := []string{settlement.ConsumerAccountID}
	if settlement.ProviderEarning != nil && settlement.ProviderEarning.AmountMicroUSD > 0 {
		accounts = append(accounts, settlement.ProviderEarning.AccountID)
	}
	if settlement.PlatformFeeMicroUSD > 0 {
		accounts = append(accounts, "platform")
	}
	if settlement.ReferralRewardMicroUSD > 0 {
		accounts = append(accounts, settlement.ReferrerAccountID)
	}
	sort.Strings(accounts)
	accounts = compactStrings(accounts)
	for _, accountID := range accounts {
		if _, err := tx.Exec(ctx,
			`INSERT INTO balances (account_id, balance_micro_usd, withdrawable_micro_usd, updated_at)
			 VALUES ($1, 0, 0, NOW()) ON CONFLICT (account_id) DO NOTHING`,
			accountID,
		); err != nil {
			return fmt.Errorf("store: ensure settlement account: %w", err)
		}
	}
	rows, err := tx.Query(ctx,
		`SELECT account_id FROM balances
		 WHERE account_id = ANY($1)
		 ORDER BY account_id
		 FOR UPDATE`,
		accounts,
	)
	if err != nil {
		return fmt.Errorf("store: lock settlement accounts: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var ignored string
		if err := rows.Scan(&ignored); err != nil {
			return fmt.Errorf("store: scan settlement account lock: %w", err)
		}
	}
	return rows.Err()
}

func reservationFundingTx(
	ctx context.Context,
	tx pgx.Tx,
	reservationID string,
) (accountID string, total, withdrawable int64, found bool, err error) {
	var accountCount int
	err = tx.QueryRow(ctx,
		`SELECT
			COALESCE(MIN(account_id), ''),
			COUNT(DISTINCT account_id),
			COALESCE(SUM(amount_micro_usd), 0),
			COALESCE(SUM(withdrawable_micro_usd), 0),
			COUNT(*) > 0
		 FROM balance_reservation_operations AS reserve
		 WHERE reserve.kind = 'reserve'
		   AND (
		       reserve.operation_key = $1
		       OR position('topup:' || $1 || ':' IN reserve.operation_key) = 1
		   )
		   AND (
		       reserve.operation_key = $1
		       OR NOT EXISTS (
		           SELECT 1 FROM balance_reservation_operations AS released
		           WHERE released.operation_key =
		                 'topup-release:' || substring(reserve.operation_key FROM 7)
		       )
		   )`,
		reservationID,
	).Scan(&accountID, &accountCount, &total, &withdrawable, &found)
	if err != nil {
		return "", 0, 0, false, fmt.Errorf("store: read reservation funding: %w", err)
	}
	if accountCount > 1 {
		return "", 0, 0, false, ErrFinancialOperationConflict
	}
	return accountID, total, withdrawable, found, nil
}

func compactStrings(values []string) []string {
	if len(values) == 0 {
		return values
	}
	out := values[:1]
	for _, value := range values[1:] {
		if value != out[len(out)-1] {
			out = append(out, value)
		}
	}
	return out
}

func creditBalanceTx(
	ctx context.Context,
	tx pgx.Tx,
	accountID string,
	amountMicroUSD, withdrawableMicroUSD int64,
	entryType LedgerEntryType,
	reference string,
) error {
	var balanceAfter int64
	if err := tx.QueryRow(ctx,
		`UPDATE balances SET
			balance_micro_usd = balance_micro_usd + $2,
			withdrawable_micro_usd = withdrawable_micro_usd + $3,
			updated_at = NOW()
		 WHERE account_id = $1
		 RETURNING balance_micro_usd`,
		accountID, amountMicroUSD, withdrawableMicroUSD,
	).Scan(&balanceAfter); err != nil {
		return fmt.Errorf("store: credit settlement balance: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO ledger_entries
			(account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, $5)`,
		accountID, string(entryType), amountMicroUSD, balanceAfter, reference,
	); err != nil {
		return fmt.Errorf("store: insert settlement ledger: %w", err)
	}
	return nil
}

func updateEarningSummaryTx(
	ctx context.Context,
	tx pgx.Tx,
	key, keyType string,
	earning *ProviderEarning,
) error {
	if _, err := tx.Exec(ctx,
		`INSERT INTO earnings_summary
			(key, key_type, total_count, total_micro_usd, total_prompt_tokens,
			 total_completion_tokens, updated_at)
		 VALUES ($1, $2, 1, $3, $4, $5, NOW())
		 ON CONFLICT (key, key_type) DO UPDATE SET
			total_count = earnings_summary.total_count + 1,
			total_micro_usd = earnings_summary.total_micro_usd + $3,
			total_prompt_tokens = earnings_summary.total_prompt_tokens + $4,
			total_completion_tokens = earnings_summary.total_completion_tokens + $5,
			updated_at = NOW()`,
		key, keyType, earning.AmountMicroUSD, earning.PromptTokens, earning.CompletionTokens,
	); err != nil {
		return fmt.Errorf("store: update settlement earning summary: %w", err)
	}
	return nil
}

func inferenceSettlementTx(
	ctx context.Context,
	tx pgx.Tx,
	reservationID string,
) (persistedInferenceSettlement, bool, error) {
	var settlement persistedInferenceSettlement
	err := tx.QueryRow(ctx,
		`SELECT request_id, consumer_account_id, reserved_micro_usd,
		        reserved_withdrawable_micro_usd, reservation_pre_debited, cost_micro_usd,
		        provider_account_id, provider_id, provider_key,
		        provider_payout_micro_usd, platform_fee_micro_usd,
		        referrer_account_id, referral_reward_micro_usd,
		        model, public_model, key_id, prompt_tokens, completion_tokens, record_usage
		 FROM inference_settlements WHERE reservation_id = $1`,
		reservationID,
	).Scan(
		&settlement.requestID, &settlement.consumerAccountID,
		&settlement.reservedMicroUSD, &settlement.reservedWithdrawableMicroUSD,
		&settlement.reservationPreDebited, &settlement.costMicroUSD, &settlement.providerAccountID,
		&settlement.providerID, &settlement.providerKey,
		&settlement.providerPayoutMicroUSD, &settlement.platformFeeMicroUSD,
		&settlement.referrerAccountID, &settlement.referralRewardMicroUSD,
		&settlement.model, &settlement.publicModel, &settlement.keyID,
		&settlement.promptTokens, &settlement.completionTokens, &settlement.recordUsage,
	)
	if errors.Is(err, pgx.ErrNoRows) {
		return persistedInferenceSettlement{}, false, nil
	}
	if err != nil {
		return persistedInferenceSettlement{}, false, fmt.Errorf("store: read inference settlement: %w", err)
	}
	return settlement, true, nil
}

func persistedSettlementMatches(
	existing persistedInferenceSettlement,
	settlement *InferenceSettlement,
) bool {
	providerAccountID, providerID, providerKey := "", "", ""
	providerPayout := int64(0)
	if settlement.ProviderEarning != nil {
		providerAccountID = settlement.ProviderEarning.AccountID
		providerID = settlement.ProviderEarning.ProviderID
		providerKey = settlement.ProviderEarning.ProviderKey
		providerPayout = settlement.ProviderEarning.AmountMicroUSD
	}
	model, publicModel, keyID := "", "", ""
	promptTokens, completionTokens := 0, 0
	recordUsage := settlement.Usage != nil
	if recordUsage {
		model = settlement.Usage.Model
		publicModel = settlement.Usage.PublicModel
		keyID = settlement.Usage.KeyID
		promptTokens = settlement.Usage.PromptTokens
		completionTokens = settlement.Usage.CompletionTokens
	} else if settlement.ProviderEarning != nil {
		model = settlement.ProviderEarning.Model
	}
	return existing.requestID == settlement.RequestID &&
		existing.consumerAccountID == settlement.ConsumerAccountID &&
		existing.reservedMicroUSD == settlement.ReservedMicroUSD &&
		existing.reservedWithdrawableMicroUSD == settlement.ReservedWithdrawableMicroUSD &&
		existing.reservationPreDebited == settlement.ReservationPreDebited &&
		existing.costMicroUSD == settlement.CostMicroUSD &&
		existing.providerAccountID == providerAccountID &&
		existing.providerID == providerID &&
		existing.providerKey == providerKey &&
		existing.providerPayoutMicroUSD == providerPayout &&
		existing.platformFeeMicroUSD == settlement.PlatformFeeMicroUSD &&
		existing.referrerAccountID == settlement.ReferrerAccountID &&
		existing.referralRewardMicroUSD == settlement.ReferralRewardMicroUSD &&
		existing.model == model &&
		existing.publicModel == publicModel &&
		existing.keyID == keyID &&
		existing.promptTokens == promptTokens &&
		existing.completionTokens == completionTokens &&
		existing.recordUsage == recordUsage
}

func insertInferenceSettlementTx(
	ctx context.Context,
	tx pgx.Tx,
	settlement *InferenceSettlement,
) error {
	providerAccountID, providerID, providerKey := "", "", ""
	providerPayout := int64(0)
	if settlement.ProviderEarning != nil {
		providerAccountID = settlement.ProviderEarning.AccountID
		providerID = settlement.ProviderEarning.ProviderID
		providerKey = settlement.ProviderEarning.ProviderKey
		providerPayout = settlement.ProviderEarning.AmountMicroUSD
	}
	model, publicModel, keyID := "", "", ""
	promptTokens, completionTokens := 0, 0
	recordUsage := settlement.Usage != nil
	var location any
	if recordUsage {
		model = settlement.Usage.Model
		publicModel = settlement.Usage.PublicModel
		keyID = settlement.Usage.KeyID
		promptTokens = settlement.Usage.PromptTokens
		completionTokens = settlement.Usage.CompletionTokens
		location = marshalProviderLocation(settlement.Usage.RequestLocation)
	} else if settlement.ProviderEarning != nil {
		model = settlement.ProviderEarning.Model
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO inference_settlements
			(reservation_id, request_id, consumer_account_id, reserved_micro_usd,
			 reserved_withdrawable_micro_usd, reservation_pre_debited, cost_micro_usd,
			 provider_account_id, provider_id, provider_key, provider_payout_micro_usd,
			 platform_fee_micro_usd, referrer_account_id, referral_reward_micro_usd,
			 model, public_model, key_id, prompt_tokens, completion_tokens,
			 record_usage, request_location)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
		         $14, $15, $16, $17, $18, $19, $20, $21)`,
		settlement.ReservationID, settlement.RequestID, settlement.ConsumerAccountID,
		settlement.ReservedMicroUSD, settlement.ReservedWithdrawableMicroUSD,
		settlement.ReservationPreDebited, settlement.CostMicroUSD,
		providerAccountID, providerID, providerKey,
		providerPayout, settlement.PlatformFeeMicroUSD, settlement.ReferrerAccountID,
		settlement.ReferralRewardMicroUSD, model, publicModel, keyID,
		promptTokens, completionTokens, recordUsage, location,
	); err != nil {
		return fmt.Errorf("store: insert inference settlement disposition: %w", err)
	}
	return nil
}
