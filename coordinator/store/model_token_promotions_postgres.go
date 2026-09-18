package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) PutModelTokenPromotion(p ModelTokenPromotion) error {
	if err := p.Validate(); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tag, err := s.pool.Exec(ctx, `INSERT INTO model_token_promotions(model_id,tokens,claim_starts_at,claim_ends_at,enabled,signup_cutoff_at,max_claims)
	 VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(model_id) DO UPDATE SET enabled=EXCLUDED.enabled
	 WHERE model_token_promotions.tokens=EXCLUDED.tokens AND model_token_promotions.claim_starts_at=EXCLUDED.claim_starts_at AND model_token_promotions.claim_ends_at IS NOT DISTINCT FROM EXCLUDED.claim_ends_at AND model_token_promotions.signup_cutoff_at=EXCLUDED.signup_cutoff_at AND model_token_promotions.max_claims=EXCLUDED.max_claims`, p.ModelID, p.Tokens, p.ClaimStartsAt, p.ClaimEndsAt, p.Enabled, p.SignupCutoffAt, p.MaxClaims)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrPromotionConflict
	}
	return err
}

func (s *PostgresStore) ListModelTokenPromotions() ([]ModelTokenPromotion, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT model_id,tokens,claim_starts_at,claim_ends_at,enabled,signup_cutoff_at,max_claims,claimed_count FROM model_token_promotions ORDER BY model_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ModelTokenPromotion{}
	for rows.Next() {
		var p ModelTokenPromotion
		if err := rows.Scan(&p.ModelID, &p.Tokens, &p.ClaimStartsAt, &p.ClaimEndsAt, &p.Enabled, &p.SignupCutoffAt, &p.MaxClaims, &p.ClaimedCount); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *PostgresStore) ClaimModelTokenPromotion(account, model string, now time.Time) ([]ModelTokenGrant, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var p ModelTokenPromotion
	err = tx.QueryRow(ctx, `SELECT model_id,tokens,claim_starts_at,claim_ends_at,enabled,signup_cutoff_at,max_claims,claimed_count FROM model_token_promotions WHERE model_id=$1 FOR UPDATE`, model).Scan(&p.ModelID, &p.Tokens, &p.ClaimStartsAt, &p.ClaimEndsAt, &p.Enabled, &p.SignupCutoffAt, &p.MaxClaims, &p.ClaimedCount)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	var user User
	err = tx.QueryRow(ctx, `SELECT account_id,privy_user_id,role,created_at FROM users WHERE account_id=$1`, account).Scan(&user.AccountID, &user.PrivyUserID, &user.Role, &user.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrPromotionIneligible
	}
	if err != nil {
		return nil, err
	}
	if user.Role == RoleService || user.PrivyUserID == "" {
		return nil, ErrPromotionIneligible
	}
	var claimed bool
	if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM model_token_grants WHERE account_id=$1 AND model_id=$2)`, account, model).Scan(&claimed); err != nil {
		return nil, err
	}
	if !claimed {
		if err = p.claimError(&user, now); err != nil {
			return nil, err
		}
		if _, err = tx.Exec(ctx, `INSERT INTO model_token_grants(account_id,model_id,total_tokens,claimed_at) VALUES($1,$2,$3,$4)`, account, model, p.Tokens, now); err != nil {
			return nil, err
		}
		if _, err = tx.Exec(ctx, `UPDATE model_token_promotions SET claimed_count=claimed_count+1 WHERE model_id=$1`, model); err != nil {
			return nil, err
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.ListModelTokenGrants(account)
}

func (s *PostgresStore) ListModelTokenGrants(account string) ([]ModelTokenGrant, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT model_id,total_tokens,used_tokens,reserved_tokens,total_tokens-used_tokens-reserved_tokens,claimed_at FROM model_token_grants WHERE account_id=$1 ORDER BY model_id`, account)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ModelTokenGrant{}
	for rows.Next() {
		var g ModelTokenGrant
		if err := rows.Scan(&g.ModelID, &g.TotalTokens, &g.UsedTokens, &g.ReservedTokens, &g.RemainingTokens, &g.ClaimedAt); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

func lockPromotionReservation(ctx context.Context, tx pgx.Tx, id string) (*ModelTokenReservation, error) {
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,0))`, "model-token:"+id); err != nil {
		return nil, err
	}
	var raw []byte
	var touched time.Time
	err := tx.QueryRow(ctx, `SELECT record,touched_at FROM model_token_reservations WHERE id=$1 FOR UPDATE`, id).Scan(&raw, &touched)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var r ModelTokenReservation
	if err = json.Unmarshal(raw, &r); err != nil {
		return nil, err
	}
	r.TouchedAt = touched
	return &r, nil
}

func savePromotionReservation(ctx context.Context, tx pgx.Tx, r ModelTokenReservation) error {
	raw, err := json.Marshal(r)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO model_token_reservations(id,account_id,model_id,state,record,created_at,touched_at) VALUES($1,$2,$3,$4,$5,$6,$6)
	 ON CONFLICT(id) DO UPDATE SET state=EXCLUDED.state,record=EXCLUDED.record`, r.ID, r.AccountID, r.ModelID, r.State, raw, r.CreatedAt)
	return err
}

func (s *PostgresStore) ReserveModelTokens(id, account, model string, tokens int64, quote ModelTokenQuote) (*ModelTokenReservation, error) {
	if id == "" || account == "" || tokens < 0 {
		return nil, errors.New("invalid promotion reservation")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	r, err := lockPromotionReservation(ctx, tx, id)
	if err != nil {
		return nil, err
	}
	if r != nil {
		if r.AccountID != account || r.ModelID != model {
			return nil, ErrPromotionConflict
		}
		return r, tx.Commit(ctx)
	}
	var remaining int64
	err = tx.QueryRow(ctx, `SELECT total_tokens-used_tokens-reserved_tokens FROM model_token_grants WHERE account_id=$1 AND model_id=$2 FOR UPDATE`, account, model).Scan(&remaining)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	free := min(tokens, remaining)
	gross, paid, err := promotionQuote(quote, free)
	if err != nil {
		return nil, err
	}
	withdrawable, err := promotionWithdrawableHold(ctx, tx, account, paid)
	if err != nil {
		return nil, err
	}
	if paid > 0 {
		if err = debitBalance(ctx, tx, account, paid, LedgerCharge, "promotion-reserve:"+id); err != nil {
			return nil, err
		}
	}
	if _, err = tx.Exec(ctx, `UPDATE model_token_grants SET reserved_tokens=reserved_tokens+$3 WHERE account_id=$1 AND model_id=$2`, account, model, free); err != nil {
		return nil, err
	}
	r = &ModelTokenReservation{ID: id, AccountID: account, ModelID: model, FreeTokens: free, ReservedMicroUSD: paid, ReservedWithdrawableMicroUSD: withdrawable, GrossReservedMicroUSD: gross, State: "reserved", CreatedAt: time.Now(), TouchedAt: time.Now()}
	if err = savePromotionReservation(ctx, tx, *r); err != nil {
		return nil, err
	}
	return r, tx.Commit(ctx)
}

func (s *PostgresStore) TopUpModelTokenReservation(id string, tokens int64, quote ModelTokenQuote) (*ModelTokenReservation, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	r, err := lockPromotionReservation(ctx, tx, id)
	if err != nil {
		return nil, err
	}
	if r == nil {
		return nil, ErrNotFound
	}
	if r.State != "reserved" {
		return nil, ErrPromotionReservationClosed
	}
	if tokens < 0 {
		return nil, errors.New("negative token reservation")
	}
	oldFree := r.FreeTokens
	if tokens > 0 {
		var available int64
		if err = tx.QueryRow(ctx, `SELECT total_tokens-used_tokens-reserved_tokens FROM model_token_grants WHERE account_id=$1 AND model_id=$2 FOR UPDATE`, r.AccountID, r.ModelID).Scan(&available); err != nil {
			return nil, err
		}
		r.FreeTokens = max(oldFree, min(tokens, oldFree+available))
		if _, err = tx.Exec(ctx, `UPDATE model_token_grants SET reserved_tokens=reserved_tokens+$3 WHERE account_id=$1 AND model_id=$2`, r.AccountID, r.ModelID, r.FreeTokens-oldFree); err != nil {
			return nil, err
		}
	}
	gross, paid, err := promotionQuote(quote, r.FreeTokens)
	if err != nil {
		return nil, err
	}
	if delta := paid - r.ReservedMicroUSD; delta > 0 {
		withdrawable, holdErr := promotionWithdrawableHold(ctx, tx, r.AccountID, delta)
		if holdErr != nil {
			return nil, holdErr
		}
		r.ReservedWithdrawableMicroUSD += withdrawable
		if err = debitBalance(ctx, tx, r.AccountID, delta, LedgerCharge, "promotion-topup:"+id); err != nil {
			return nil, err
		}
	}
	r.ReservedMicroUSD = max(r.ReservedMicroUSD, paid)
	r.GrossReservedMicroUSD = max(r.GrossReservedMicroUSD, gross)
	if err = savePromotionReservation(ctx, tx, *r); err != nil {
		return nil, err
	}
	return r, tx.Commit(ctx)
}
