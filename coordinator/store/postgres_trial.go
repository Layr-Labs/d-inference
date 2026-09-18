package store

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
)

const trialReservationColumns = `id,account_id,campaign_id,model,limit_tokens,reserved_tokens,used_tokens,state,pricing_json,created_at,updated_at`

func scanTrialReservation(row pgx.Row) (TrialReservation, error) {
	var r TrialReservation
	var pricing string
	err := row.Scan(&r.ID, &r.AccountID, &r.CampaignID, &r.Model, &r.LimitTokens, &r.ReservedTokens, &r.UsedTokens, &r.State, &pricing, &r.CreatedAt, &r.UpdatedAt)
	r.PricingJSON = []byte(pricing)
	if errors.Is(err, pgx.ErrNoRows) {
		return r, ErrTrialNotFound
	}
	return r, err
}
func trialStoreError(err error) error {
	if err == nil {
		return nil
	}
	for _, expected := range []error{ErrTrialExhausted, ErrTrialBusy, ErrTrialRequestTooLarge, ErrTrialConflict, ErrTrialInvalidUsage, ErrTrialNotFound} {
		if errors.Is(err, expected) {
			return err
		}
	}
	return errors.Join(ErrTrialUnavailable, err)
}
func (s *PostgresStore) GetTrialReservation(ctx context.Context, id string) (TrialReservation, error) {
	r, err := scanTrialReservation(s.pool.QueryRow(ctx, `SELECT `+trialReservationColumns+` FROM trial_reservations WHERE id=$1`, id))
	return r, trialStoreError(err)
}
func (s *PostgresStore) GetTrialAllowance(ctx context.Context, account, campaign string) (TrialAllowance, error) {
	a := TrialAllowance{AccountID: account, CampaignID: campaign}
	err := s.pool.QueryRow(ctx, `SELECT limit_tokens,used_tokens,reserved_tokens FROM trial_allowances WHERE account_id=$1 AND campaign_id=$2`, account, campaign).Scan(&a.LimitTokens, &a.UsedTokens, &a.ReservedTokens)
	if errors.Is(err, pgx.ErrNoRows) {
		err = ErrTrialNotFound
	}
	return a, trialStoreError(err)
}
func (s *PostgresStore) ReserveTrial(ctx context.Context, r TrialReservation) (out TrialReservation, err error) {
	defer func() { err = trialStoreError(err) }()
	if err = validateTrialReservation(r); err != nil {
		return out, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return out, err
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `INSERT INTO trial_allowances(account_id,campaign_id,limit_tokens) VALUES($1,$2,$3) ON CONFLICT DO NOTHING`, r.AccountID, r.CampaignID, r.LimitTokens)
	if err != nil {
		return out, err
	}
	a := TrialAllowance{AccountID: r.AccountID, CampaignID: r.CampaignID}
	err = tx.QueryRow(ctx, `SELECT limit_tokens,used_tokens,reserved_tokens FROM trial_allowances WHERE account_id=$1 AND campaign_id=$2 FOR UPDATE`, r.AccountID, r.CampaignID).Scan(&a.LimitTokens, &a.UsedTokens, &a.ReservedTokens)
	if err != nil {
		return out, err
	}
	old, lookupErr := scanTrialReservation(tx.QueryRow(ctx, `SELECT `+trialReservationColumns+` FROM trial_reservations WHERE id=$1`, r.ID))
	if lookupErr == nil {
		if !sameTrialReservation(old, r) {
			return out, ErrTrialConflict
		}
		return old, nil
	}
	if !errors.Is(lookupErr, ErrTrialNotFound) {
		return out, lookupErr
	}
	if a.LimitTokens != r.LimitTokens {
		return out, ErrTrialConflict
	}
	if err = trialAdmissionError(a, r.ReservedTokens); err != nil {
		if err == ErrTrialBusy {
			var unresolved bool
			lookupErr := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM trial_reservations WHERE account_id=$1 AND campaign_id=$2 AND state='unresolved')`, r.AccountID, r.CampaignID).Scan(&unresolved)
			if lookupErr != nil {
				return out, lookupErr
			}
			if unresolved {
				return out, ErrTrialUnavailable
			}
		}
		return out, err
	}
	tag, err := tx.Exec(ctx, `INSERT INTO trial_reservations(id,account_id,campaign_id,model,limit_tokens,reserved_tokens,state,pricing_json) VALUES($1,$2,$3,$4,$5,$6,'reserved',$7) ON CONFLICT DO NOTHING`, r.ID, r.AccountID, r.CampaignID, r.Model, r.LimitTokens, r.ReservedTokens, string(r.PricingJSON))
	if err != nil {
		return out, err
	}
	if tag.RowsAffected() != 1 {
		return out, ErrTrialConflict
	}
	_, err = tx.Exec(ctx, `UPDATE trial_allowances SET reserved_tokens=reserved_tokens+$3 WHERE account_id=$1 AND campaign_id=$2`, r.AccountID, r.CampaignID, r.ReservedTokens)
	if err != nil {
		return out, err
	}
	out, err = scanTrialReservation(tx.QueryRow(ctx, `SELECT `+trialReservationColumns+` FROM trial_reservations WHERE id=$1`, r.ID))
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
func (s *PostgresStore) MarkTrialDispatched(ctx context.Context, id string) error {
	tag, err := s.pool.Exec(ctx, `UPDATE trial_reservations SET state='dispatched',updated_at=NOW() WHERE id=$1 AND state IN ('reserved','dispatched')`, id)
	if err != nil {
		return trialStoreError(err)
	}
	if tag.RowsAffected() != 1 {
		if _, err := s.GetTrialReservation(ctx, id); err != nil {
			return err
		}
		return ErrTrialConflict
	}
	return nil
}
func (s *PostgresStore) ReleaseTrial(ctx context.Context, id string, confirmedUnused bool) (err error) {
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
	if r.State == TrialReleased || r.State == TrialSettled {
		return nil
	}
	if r.State == TrialUnresolved && confirmedUnused {
		return ErrTrialConflict
	}
	state := TrialUnresolved
	if r.State == TrialReserved || confirmedUnused {
		state = TrialReleased
		_, err = tx.Exec(ctx, `UPDATE trial_allowances SET reserved_tokens=reserved_tokens-$3 WHERE account_id=$1 AND campaign_id=$2`, r.AccountID, r.CampaignID, r.ReservedTokens)
		if err != nil {
			return err
		}
	}
	_, err = tx.Exec(ctx, `UPDATE trial_reservations SET state=$2,updated_at=NOW() WHERE id=$1`, id, state)
	if err != nil {
		return err
	}
	return tx.Commit(ctx)
}

var _ TrialStore = (*PostgresStore)(nil)
