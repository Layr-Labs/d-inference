package store

import "context"

// SettleTrial commits the quota, zero-charge usage, subsidy, and existing
// provider earning/withdrawable/ledger/summary writes in one transaction.
func (s *PostgresStore) SettleTrial(ctx context.Context, id string, settlement TrialSettlement) (err error) {
	defer func() { err = trialStoreError(err) }()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	r, err := scanTrialReservation(tx.QueryRow(ctx, `SELECT `+trialReservationColumns+` FROM trial_reservations WHERE id=$1 FOR UPDATE`, id))
	if err != nil {
		return err
	}
	if r.State == TrialSettled {
		return nil
	}
	if r.State == TrialReleased || r.State == TrialReserved {
		return ErrTrialConflict
	}
	tokens, usageErr := validateTrialSettlement(r, settlement)
	if usageErr != nil {
		if _, err = tx.Exec(ctx, `UPDATE trial_reservations SET state='unresolved',updated_at=NOW() WHERE id=$1`, id); err != nil {
			return err
		}
		if err = tx.Commit(ctx); err != nil {
			return err
		}
		return usageErr
	}
	// Lock the allowance before touching any financial rows; all trial settlers
	// use the same lock order. Counter constraints are an additional guard.
	_, err = tx.Exec(ctx, `UPDATE trial_allowances SET reserved_tokens=reserved_tokens-$3,used_tokens=used_tokens+$4 WHERE account_id=$1 AND campaign_id=$2`, r.AccountID, r.CampaignID, r.ReservedTokens, tokens)
	if err != nil {
		return err
	}
	credit := int64(0)
	if e := settlement.Earning; e != nil {
		credit = e.AmountMicroUSD
		if err = creditProviderAccount(ctx, tx, e, true); err != nil {
			return err
		}
	}
	u := settlement.Usage
	_, err = tx.Exec(ctx, `WITH ins AS (
 INSERT INTO usage(provider_id,consumer_key_hash,key_id,model,public_model,prompt_tokens,completion_tokens,request_id,cost_micro_usd,request_location)
 VALUES($1,$2,'',$3,$4,$5,$6,$7,0,$8))
 UPDATE usage_totals SET total_requests=total_requests+1,total_prompt_tokens=total_prompt_tokens+$5,total_completion_tokens=total_completion_tokens+$6 WHERE id=1`, u.ProviderID, hashKey(u.ConsumerKey), u.Model, u.PublicModel, u.PromptTokens, u.CompletionTokens, u.RequestID, marshalProviderLocation(u.RequestLocation))
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO trial_subsidies(reservation_id,subsidy_micro_usd,provider_credit_micro_usd,serving_request_id) VALUES($1,$2,$3,$4)`, id, settlement.SubsidyMicroUSD, credit, settlement.ServingRequestID)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE trial_reservations SET state='settled',used_tokens=$2,updated_at=NOW() WHERE id=$1`, id, tokens)
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}
