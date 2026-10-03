package store

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/storedb"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// erasureTimeout bounds one erasure transaction. The scrub is bounded by the
// collected keys, so it stays well inside this even for a large account.
const erasureTimeout = 2 * time.Minute

var _ AccountErasureStore = (*PostgresStore)(nil)

func (s *PostgresStore) erasureTx(ctx context.Context, opts pgx.TxOptions, fn func(*storedb.Queries) error) error {
	ctx, cancel := context.WithTimeout(ctx, erasureTimeout)
	defer cancel()
	tx, err := s.pool.BeginTx(ctx, opts)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := fn(storedb.New(tx)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func erasureRequestFromRow(r storedb.ErasureRequest) (*ErasureRequest, error) {
	out := &ErasureRequest{
		ID: r.ID, AccountID: r.AccountID, Actor: r.Actor, CanceledBy: r.CanceledBy, Reason: r.Reason,
		State: ErasureState(r.State), ConfirmExpiresAt: r.ConfirmExpiresAt, WalletAddressCount: len(r.WalletAddresses),
		RequestedAt: r.RequestedAt, ScrubAfter: r.ScrubAfter, ErasedAt: r.ErasedAt, CanceledAt: r.CanceledAt,
		LastError: r.LastError, CreatedAt: r.CreatedAt,
	}
	if len(r.Plan) > 0 {
		if err := json.Unmarshal(r.Plan, &out.Summary); err != nil {
			return nil, fmt.Errorf("store: decode erasure plan: %w", err)
		}
	}
	return out, nil
}

// openWithdrawals counts withdrawals whose money is still moving: Stripe
// withdrawals that are not terminal or wait for a confirmed-rejection refund,
// and Global Payouts that are pending, processing, or posted recently enough
// that the reconciler still reads them.
func openWithdrawals(ctx context.Context, q *storedb.Queries, accountID string, now time.Time) (int64, error) {
	stripe, err := q.CountOpenStripeWithdrawals(ctx, storedb.CountOpenStripeWithdrawalsParams{AccountID: accountID, RefundPrefix: StripeConfirmedRejectionPrefix})
	if err != nil {
		return 0, err
	}
	global, err := q.CountOpenGlobalPayouts(ctx, storedb.CountOpenGlobalPayoutsParams{AccountID: accountID, PostedAfter: now.Add(-globalPayoutReconcileWindow)})
	if err != nil {
		return 0, err
	}
	return stripe + global, nil
}

// countRules reads the count query of every rule.
func countRules(ctx context.Context, q *storedb.Queries, k *erasureKeys) ([]ErasureRowCount, error) {
	out := make([]ErasureRowCount, 0, len(erasureRules))
	for _, rule := range erasureRules {
		row := ErasureRowCount{Rule: rule.Name, Table: rule.Table, Columns: rule.columnNames(), Action: rule.action()}
		for _, st := range rule.statements(k) {
			n, err := st.count(ctx, q)
			if err != nil {
				return nil, fmt.Errorf("store: erasure count %s: %w", rule.Name, err)
			}
			row.Rows += n
		}
		out = append(out, row)
	}
	return out, nil
}

// PlanAccountErasure is a read-only dry run.
func (s *PostgresStore) PlanAccountErasure(ctx context.Context, accountID string, walletAddresses []string) (*ErasurePlan, error) {
	var plan *ErasurePlan
	err := s.erasureTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(q *storedb.Queries) error {
		user, err := q.GetUserForErasurePlan(ctx, accountID)
		if noRows(err) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		k, err := collectErasureKeys(ctx, q, accountID, user.StripeAccountID, walletAddresses)
		if err != nil {
			return err
		}
		rows, err := countRules(ctx, q, k)
		if err != nil {
			return err
		}
		open, err := openWithdrawals(ctx, q, accountID, time.Now())
		if err != nil {
			return err
		}
		plan = &ErasurePlan{AccountID: accountID, Email: user.Email, StripeObjects: k.stripeObjects()}
		plan.Rows, plan.Retained, plan.OpenWithdrawals = rows, k.retained(), open
		plan.StripeObjectCounts = stripeObjectCounts(plan.StripeObjects)
		bal, err := q.GetBalanceForErasure(ctx, accountID)
		if err != nil && !noRows(err) {
			return err
		}
		plan.BalanceMicroUSD, plan.WithdrawableMicroUSD = bal.BalanceMicroUsd, bal.WithdrawableMicroUsd
		return nil
	})
	return plan, err
}

// SaveErasurePlan stores or replaces the planned request of the account.
func (s *PostgresStore) SaveErasurePlan(ctx context.Context, accountID, actor string, counts ErasureCounts, confirmToken string, expiresAt time.Time) (*ErasureRequest, error) {
	raw, err := json.Marshal(ErasureSummary{Planned: &counts})
	if err != nil {
		return nil, err
	}
	var id string
	err = s.erasureTx(ctx, pgx.TxOptions{}, func(q *storedb.Queries) error {
		if _, err := q.LockLiveUserForErasure(ctx, accountID); noRows(err) {
			return ErrNotFound
		} else if err != nil {
			return err
		}
		open, err := q.GetOpenErasureRequestForUpdate(ctx, accountID)
		switch {
		case noRows(err):
			id = uuid.NewString()
			return q.InsertErasurePlan(ctx, storedb.InsertErasurePlanParams{
				ID: id, AccountID: accountID, Actor: actor, Plan: raw,
				ConfirmTokenHash: erasureTokenHash(confirmToken), ConfirmExpiresAt: &expiresAt,
			})
		case err != nil:
			return err
		case open.State != string(ErasurePlanned):
			return ErrErasureConflict
		}
		id = open.ID
		return q.UpdateErasurePlan(ctx, storedb.UpdateErasurePlanParams{
			ID: id, Actor: actor, Plan: raw, ConfirmTokenHash: erasureTokenHash(confirmToken), ConfirmExpiresAt: &expiresAt,
		})
	})
	if isUniqueViolation(err) {
		return nil, ErrErasureConflict
	}
	if err != nil {
		return nil, err
	}
	return s.getErasureRequest(ctx, id)
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

func normalizeErasureEmail(email string) string { return strings.ToLower(strings.TrimSpace(email)) }

// RequestAccountErasure soft deletes the account after checking the token
// and the email.
func (s *PostgresStore) RequestAccountErasure(ctx context.Context, in ErasureConfirm) (*ErasureRequest, error) {
	var id string
	err := s.erasureTx(ctx, pgx.TxOptions{}, func(q *storedb.Queries) error {
		open, err := q.GetOpenErasureRequestForUpdate(ctx, in.AccountID)
		if noRows(err) {
			return ErrErasureConfirmToken
		}
		if err != nil {
			return err
		}
		if open.State != string(ErasurePlanned) {
			return ErrErasureConflict
		}
		if !erasureTokenValid(open.ConfirmTokenHash, open.ConfirmExpiresAt, in.ConfirmToken, in.Now) {
			return ErrErasureConfirmToken
		}
		user, err := q.LockLiveUserForErasure(ctx, in.AccountID)
		if noRows(err) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if normalizeErasureEmail(user.Email) != normalizeErasureEmail(in.Email) {
			return ErrErasureEmailMismatch
		}
		if n, err := openWithdrawals(ctx, q, in.AccountID, in.Now); err != nil {
			return err
		} else if n > 0 {
			return ErrErasureOpenWithdrawal
		}
		now := in.Now
		if _, err := q.SoftDeleteUser(ctx, storedb.SoftDeleteUserParams{AccountID: in.AccountID, DeletedAt: &now}); err != nil {
			return err
		}
		if _, err := q.SoftDeleteProviders(ctx, storedb.SoftDeleteProvidersParams{AccountID: in.AccountID, DeletedAt: &now}); err != nil {
			return err
		}
		if _, err := q.SoftDeleteAPIKeys(ctx, storedb.SoftDeleteAPIKeysParams{OwnerAccountID: in.AccountID, DeletedAt: &now}); err != nil {
			return err
		}
		if _, err := q.SoftDeleteProviderTokens(ctx, storedb.SoftDeleteProviderTokensParams{AccountID: in.AccountID, DeletedAt: &now}); err != nil {
			return err
		}
		scrubAfter := now.Add(in.Grace)
		id = open.ID
		return q.MarkErasurePending(ctx, storedb.MarkErasurePendingParams{
			ID: id, Actor: in.Actor, Reason: in.Reason, WalletAddresses: normalizeWallets(in.WalletAddresses),
			RequestedAt: &now, ScrubAfter: &scrubAfter,
		})
	})
	if err != nil {
		return nil, err
	}
	return s.getErasureRequest(ctx, id)
}

func erasureTokenValid(storedHash string, expires *time.Time, token string, now time.Time) bool {
	if storedHash == "" || token == "" || expires == nil || !now.Before(*expires) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(storedHash), []byte(erasureTokenHash(token))) == 1
}

// CancelAccountErasure restores the user and providers of a pending request.
func (s *PostgresStore) CancelAccountErasure(ctx context.Context, accountID, actor string, now time.Time) (*ErasureRequest, error) {
	var id string
	err := s.erasureTx(ctx, pgx.TxOptions{}, func(q *storedb.Queries) error {
		open, err := q.GetOpenErasureRequestForUpdate(ctx, accountID)
		if noRows(err) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if open.State != string(ErasurePending) || open.ScrubAfter == nil || !now.Before(*open.ScrubAfter) {
			return ErrErasureConflict
		}
		if _, err := q.LockUserForErasure(ctx, accountID); err != nil {
			return err
		}
		if _, err := q.RestoreUser(ctx, accountID); err != nil {
			return fmt.Errorf("store: restore user: %w", err)
		}
		if _, err := q.RestoreProviders(ctx, accountID); err != nil {
			return err
		}
		id = open.ID
		return q.MarkErasureCanceled(ctx, storedb.MarkErasureCanceledParams{ID: id, CanceledBy: actor, CanceledAt: &now})
	})
	if err != nil {
		return nil, err
	}
	return s.getErasureRequest(ctx, id)
}

// ScrubAccount removes the personal data of a pending request in one
// transaction.
func (s *PostgresStore) ScrubAccount(ctx context.Context, requestID string, now time.Time) (*ErasureResult, error) {
	var result ErasureResult
	err := s.erasureTx(ctx, pgx.TxOptions{}, func(q *storedb.Queries) error {
		req, err := q.GetErasureRequestForUpdate(ctx, requestID)
		if noRows(err) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if req.State != string(ErasurePending) {
			return ErrErasureConflict
		}
		user, err := q.LockUserForErasure(ctx, req.AccountID)
		if noRows(err) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if user.DeletedAt == nil {
			return ErrErasureConflict
		}
		if n, err := openWithdrawals(ctx, q, req.AccountID, now); err != nil {
			return err
		} else if n > 0 {
			return ErrErasureOpenWithdrawal
		}
		k, err := collectErasureKeys(ctx, q, req.AccountID, user.StripeAccountID, req.WalletAddresses)
		if err != nil {
			return err
		}
		applied := ErasureCounts{Retained: k.retained()}
		if applied.BalanceMicroUSD, applied.WithdrawableMicroUSD, err = forfeitBalance(ctx, q, req.AccountID, req.ID); err != nil {
			return err
		}
		if applied.Rows, err = applyRules(ctx, q, k); err != nil {
			return err
		}
		outbox := k.outboxRows()
		applied.StripeObjectCounts = stripeObjectCounts(k.stripeObjects())
		for _, o := range outbox {
			if err := q.InsertErasureOutbox(ctx, storedb.InsertErasureOutboxParams{
				ID: o.ID, RequestID: req.ID, Target: string(o.Target), ExternalID: o.ExternalID, NextAt: now,
			}); err != nil {
				return err
			}
		}
		summary := ErasureSummary{Applied: &applied}
		if len(req.Plan) > 0 {
			var stored ErasureSummary
			if err := json.Unmarshal(req.Plan, &stored); err == nil {
				summary.Planned = stored.Planned
			}
		}
		raw, err := json.Marshal(summary)
		if err != nil {
			return err
		}
		if err := q.MarkErasureErased(ctx, storedb.MarkErasureErasedParams{ID: req.ID, ErasedAt: &now, Plan: raw}); err != nil {
			return err
		}
		result.SEKeys, result.ProviderIDs = k.SEKeys, k.ProviderIDs
		return nil
	})
	if err != nil {
		return nil, err
	}
	if result.Request, err = s.getErasureRequest(ctx, requestID); err != nil {
		return nil, err
	}
	return &result, nil
}

// forfeitBalance zeroes both balances and records one erasure_forfeit ledger
// entry for the removed amount, so the ledger still sums to the balance.
func forfeitBalance(ctx context.Context, q *storedb.Queries, accountID, requestID string) (int64, int64, error) {
	bal, err := q.LockBalance(ctx, accountID)
	if noRows(err) {
		return 0, 0, nil
	}
	if err != nil {
		return 0, 0, err
	}
	if bal.BalanceMicroUsd == 0 && bal.WithdrawableMicroUsd == 0 {
		return 0, 0, nil
	}
	if n, err := q.ZeroBalance(ctx, accountID); err != nil {
		return 0, 0, err
	} else if n != 1 {
		return 0, 0, fmt.Errorf("%w: balances counted 1, changed %d", ErrErasureCountMismatch, n)
	}
	if err := q.InsertErasureLedgerEntry(ctx, storedb.InsertErasureLedgerEntryParams{
		AccountID: accountID, EntryType: string(LedgerErasureForfeit),
		AmountMicroUsd: -bal.BalanceMicroUsd, Reference: "erasure:" + requestID,
	}); err != nil {
		return 0, 0, err
	}
	return bal.BalanceMicroUsd, bal.WithdrawableMicroUsd, nil
}

// applyRules runs every rule statement and checks its affected rows against
// the count read just before in the same transaction.
func applyRules(ctx context.Context, q *storedb.Queries, k *erasureKeys) ([]ErasureRowCount, error) {
	out := make([]ErasureRowCount, 0, len(erasureRules))
	for _, rule := range erasureRules {
		row := ErasureRowCount{Rule: rule.Name, Table: rule.Table, Columns: rule.columnNames(), Action: rule.action()}
		for _, st := range rule.statements(k) {
			want, err := st.count(ctx, q)
			if err != nil {
				return nil, fmt.Errorf("store: erasure count %s: %w", rule.Name, err)
			}
			got, err := st.apply(ctx, q)
			if err != nil {
				return nil, fmt.Errorf("store: erasure apply %s: %w", rule.Name, err)
			}
			if got != want {
				return nil, fmt.Errorf("%w: %s counted %d, changed %d", ErrErasureCountMismatch, rule.Name, want, got)
			}
			row.Rows += got
		}
		out = append(out, row)
	}
	return out, nil
}

func (s *PostgresStore) getErasureRequest(ctx context.Context, id string) (*ErasureRequest, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	row, err := s.queries().GetErasureRequest(ctx, id)
	if noRows(err) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return erasureRequestFromRow(row)
}

// GetAccountErasure returns the newest request and its outbox rows.
func (s *PostgresStore) GetAccountErasure(ctx context.Context, accountID string) (*ErasureRequest, []ErasureOutboxItem, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	q := s.queries()
	row, err := q.GetLatestErasureRequest(ctx, accountID)
	if noRows(err) {
		return nil, nil, ErrNotFound
	}
	if err != nil {
		return nil, nil, err
	}
	req, err := erasureRequestFromRow(row)
	if err != nil {
		return nil, nil, err
	}
	rows, err := q.ListErasureOutbox(ctx, row.ID)
	if err != nil {
		return nil, nil, err
	}
	items := make([]ErasureOutboxItem, 0, len(rows))
	for _, r := range rows {
		items = append(items, ErasureOutboxItem{
			ID: r.ID, RequestID: r.RequestID, Target: ErasureTarget(r.Target), State: ErasureOutboxState(r.State),
			Attempts: int(r.Attempts), NextAt: r.NextAt, LastError: r.LastError, DoneAt: r.DoneAt,
			HasExternalID: r.ExternalID != "", ExternalID: r.ExternalID, CreatedAt: r.CreatedAt,
			HasStripeJob: r.StripeJobID != "", StripeJobID: r.StripeJobID,
		})
	}
	return req, items, nil
}

// LeaseDueAccountErasures leases due pending requests with FOR UPDATE SKIP
// LOCKED, so two coordinators never scrub the same request at once.
func (s *PostgresStore) LeaseDueAccountErasures(ctx context.Context, now time.Time, lease time.Duration, limit int) ([]string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return s.queries().LeaseDueErasureRequests(ctx, storedb.LeaseDueErasureRequestsParams{
		Now: now, LeaseUntil: now.Add(lease), MaxRows: int32(limit),
	})
}

// RecordAccountErasureFailure stores the last scrub error.
func (s *PostgresStore) RecordAccountErasureFailure(ctx context.Context, requestID, message string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return s.queries().RecordErasureFailure(ctx, storedb.RecordErasureFailureParams{ID: requestID, LastError: message})
}

// PrivyUserPendingErasure reports whether a soft-deleted user holds the
// Privy ID. After the scrub the stored ID is random and never matches.
func (s *PostgresStore) PrivyUserPendingErasure(ctx context.Context, privyUserID string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	n, err := s.queries().CountUsersPendingErasureByPrivyID(ctx, privyUserID)
	return n > 0, err
}

// LeaseDueErasureOutbox leases due outbox rows with FOR UPDATE SKIP LOCKED.
func (s *PostgresStore) LeaseDueErasureOutbox(ctx context.Context, now time.Time, lease time.Duration, limit int) ([]ErasureOutboxWork, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	rows, err := s.queries().LeaseDueErasureOutbox(ctx, storedb.LeaseDueErasureOutboxParams{
		Now: now, LeaseUntil: now.Add(lease), MaxRows: int32(limit),
	})
	if err != nil {
		return nil, err
	}
	out := make([]ErasureOutboxWork, 0, len(rows))
	for _, r := range rows {
		w := ErasureOutboxWork{AccountID: r.AccountID, ErasureOutboxItem: ErasureOutboxItem{
			ID: r.ID, RequestID: r.RequestID, Target: ErasureTarget(r.Target), State: ErasureOutboxState(r.State),
			Attempts: int(r.Attempts), NextAt: r.NextAt, LastError: r.LastError, CreatedAt: r.CreatedAt,
			ExternalID: r.ExternalID, HasExternalID: r.ExternalID != "", StripeJobID: r.StripeJobID, HasStripeJob: r.StripeJobID != "",
		}}
		if r.ErasedAt != nil {
			w.ErasedAt = *r.ErasedAt
		}
		out = append(out, w)
	}
	return out, nil
}

// SaveErasureOutboxResult stores one delivery outcome.
func (s *PostgresStore) SaveErasureOutboxResult(ctx context.Context, id string, r ErasureOutboxResult) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	n, err := s.queries().SaveErasureOutboxResult(ctx, storedb.SaveErasureOutboxResultParams{
		ID: id, State: string(r.State), Attempts: int32(r.Attempts), NextAt: r.NextAt,
		LastError: r.LastError, StripeJobID: r.StripeJobID,
	})
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrErasureConflict
	}
	return nil
}
