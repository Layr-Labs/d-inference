package store

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// --- Users (Privy) ---

// CreateUser creates a new user record linked to a Privy identity.
func (s *PostgresStore) CreateUser(user *User) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := s.pool.Exec(ctx,
		`INSERT INTO users (account_id, privy_user_id, email, role, platform_fee_percent)
		 VALUES ($1, $2, $3, $4, $5)`,
		user.AccountID, user.PrivyUserID, user.Email, user.Role, user.PlatformFeePercent,
	)
	if err != nil {
		return fmt.Errorf("store: create user: %w", err)
	}
	return nil
}

const userSelectColumns = `account_id, privy_user_id, email, role, platform_fee_percent,
	stripe_account_id, stripe_account_status, stripe_destination_type,
	stripe_destination_last4, stripe_instant_eligible, created_at`

func scanUser(row interface {
	Scan(...any) error
}) (*User, error) {
	var u User
	if err := row.Scan(&u.AccountID, &u.PrivyUserID, &u.Email, &u.Role, &u.PlatformFeePercent,
		&u.StripeAccountID, &u.StripeAccountStatus, &u.StripeDestinationType,
		&u.StripeDestinationLast4, &u.StripeInstantEligible, &u.CreatedAt); err != nil {
		return nil, err
	}
	return &u, nil
}

// GetUserByPrivyID returns the user for a Privy DID.
func (s *PostgresStore) GetUserByPrivyID(privyUserID string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+userSelectColumns+` FROM users WHERE privy_user_id = $1`, privyUserID,
	)
	u, err := scanUser(row)
	if err != nil {
		return nil, fmt.Errorf("store: user not found: %w", err)
	}
	return u, nil
}

// GetUserByAccountID returns the user for an internal account ID.
func (s *PostgresStore) GetUserByAccountID(accountID string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+userSelectColumns+` FROM users WHERE account_id = $1`, accountID,
	)
	u, err := scanUser(row)
	if err != nil {
		return nil, fmt.Errorf("store: user not found: %w", err)
	}
	return u, nil
}

// SetUserStripeAccount upserts the Stripe Connect fields on a user record.
func (s *PostgresStore) SetUserStripeAccount(accountID, stripeAccountID, status, destinationType, destinationLast4 string, instantEligible bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE users SET
			stripe_account_id = $2,
			stripe_account_status = $3,
			stripe_destination_type = $4,
			stripe_destination_last4 = $5,
			stripe_instant_eligible = $6
		 WHERE account_id = $1`,
		accountID, stripeAccountID, status, destinationType, destinationLast4, instantEligible,
	)
	if err != nil {
		return fmt.Errorf("store: set stripe account: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	return nil
}

// GetUserByStripeAccount finds a user by their Stripe connected account ID.
func (s *PostgresStore) GetUserByStripeAccount(stripeAccountID string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+userSelectColumns+` FROM users WHERE stripe_account_id = $1`, stripeAccountID,
	)
	u, err := scanUser(row)
	if err != nil {
		return nil, fmt.Errorf("store: user with Stripe account %q not found: %w", stripeAccountID, err)
	}
	return u, nil
}

// SetUserRole sets the account role on a user record.
func (s *PostgresStore) SetUserRole(accountID, role string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE users SET role = $2 WHERE account_id = $1`,
		accountID, role,
	)
	if err != nil {
		return fmt.Errorf("store: set user role: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	return nil
}

// SetUserPlatformFeePercent sets (or clears, when nil) the per-account platform
// fee override.
func (s *PostgresStore) SetUserPlatformFeePercent(accountID string, feePercent *int64) error {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE users SET platform_fee_percent = $2 WHERE account_id = $1`,
		accountID, feePercent,
	)
	if err != nil {
		return fmt.Errorf("store: set user platform fee: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("user with account ID %q not found", accountID)
	}
	return nil
}

// GetUserByEmail returns the user for an email address.
func (s *PostgresStore) GetUserByEmail(email string) (*User, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	row := s.pool.QueryRow(ctx,
		`SELECT `+userSelectColumns+` FROM users WHERE LOWER(email) = LOWER($1)`, email,
	)
	u, err := scanUser(row)
	if err != nil {
		return nil, fmt.Errorf("user with email %q not found", email)
	}
	return u, nil
}

// --- Stripe Withdrawals ---

func (s *PostgresStore) CreateStripeWithdrawal(w *StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	now := time.Now()
	if w.CreatedAt.IsZero() {
		w.CreatedAt = now
	}
	if w.UpdatedAt.IsZero() {
		w.UpdatedAt = w.CreatedAt
	}

	_, err := s.pool.Exec(ctx,
		`INSERT INTO stripe_withdrawals
		 (id, account_id, stripe_account_id, transfer_id, payout_id,
		  amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
		  failure_reason, refunded, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
		w.ID, w.AccountID, w.StripeAccountID, w.TransferID, w.PayoutID,
		w.AmountMicroUSD, w.FeeMicroUSD, w.NetMicroUSD, w.Method, w.Status,
		w.FailureReason, w.Refunded, w.CreatedAt, w.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("store: create stripe withdrawal: %w", err)
	}
	return nil
}

const stripeWithdrawalSelectColumns = `id, account_id, stripe_account_id, transfer_id, payout_id,
	amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
	failure_reason, refunded, created_at, updated_at`

func scanStripeWithdrawal(row interface{ Scan(...any) error }) (*StripeWithdrawal, error) {
	var w StripeWithdrawal
	if err := row.Scan(&w.ID, &w.AccountID, &w.StripeAccountID, &w.TransferID, &w.PayoutID,
		&w.AmountMicroUSD, &w.FeeMicroUSD, &w.NetMicroUSD, &w.Method, &w.Status,
		&w.FailureReason, &w.Refunded, &w.CreatedAt, &w.UpdatedAt); err != nil {
		return nil, err
	}
	return &w, nil
}

func (s *PostgresStore) GetStripeWithdrawal(id string) (*StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE id = $1`, id)
	w, err := scanStripeWithdrawal(row)
	if err != nil {
		return nil, fmt.Errorf("store: stripe withdrawal %q not found: %w", id, err)
	}
	return w, nil
}

func (s *PostgresStore) GetStripeWithdrawalByPayoutID(payoutID string) (*StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE payout_id = $1`, payoutID)
	w, err := scanStripeWithdrawal(row)
	if err != nil {
		return nil, fmt.Errorf("store: stripe withdrawal with payout %q not found: %w", payoutID, err)
	}
	return w, nil
}

func (s *PostgresStore) GetStripeWithdrawalByTransferID(transferID string) (*StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE transfer_id = $1`, transferID)
	w, err := scanStripeWithdrawal(row)
	if err != nil {
		return nil, fmt.Errorf("store: stripe withdrawal with transfer %q not found: %w", transferID, err)
	}
	return w, nil
}

func (s *PostgresStore) UpdateStripeWithdrawal(w *StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tag, err := s.pool.Exec(ctx,
		`UPDATE stripe_withdrawals SET
			transfer_id = $2, payout_id = $3, status = $4,
			failure_reason = $5, refunded = $6, updated_at = NOW()
		 WHERE id = $1`,
		w.ID, w.TransferID, w.PayoutID, w.Status, w.FailureReason, w.Refunded,
	)
	if err != nil {
		return fmt.Errorf("store: update stripe withdrawal: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("stripe withdrawal %q not found", w.ID)
	}
	w.UpdatedAt = time.Now()
	return nil
}

func (s *PostgresStore) ListStripeWithdrawals(accountID string, limit int) ([]StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	q := `SELECT ` + stripeWithdrawalSelectColumns + ` FROM stripe_withdrawals WHERE account_id = $1 ORDER BY created_at DESC`
	args := []any{accountID}
	if limit > 0 {
		q += ` LIMIT $2`
		args = append(args, limit)
	}
	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("store: list stripe withdrawals: %w", err)
	}
	defer rows.Close()

	var out []StripeWithdrawal
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan stripe withdrawal: %w", err)
		}
		out = append(out, *w)
	}
	if out == nil {
		return []StripeWithdrawal{}, nil
	}
	return out, nil
}
