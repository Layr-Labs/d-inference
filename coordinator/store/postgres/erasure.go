package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres/storedb"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// erasureTimeout bounds one erasure transaction. The scrub is bounded by the
// collected keys, so it stays well inside this even for a large account.
const erasureTimeout = 2 * time.Minute

var _ store.AccountErasureStore = (*PostgresStore)(nil)

func (s *PostgresStore) erasureTx(ctx context.Context, opts pgx.TxOptions, fn func(context.Context, *storedb.Queries) error) error {
	ctx, cancel := context.WithTimeout(ctx, erasureTimeout)
	defer cancel()
	tx, err := s.pool.BeginTx(ctx, opts)
	if err != nil {
		return err
	}
	defer rollbackErasureTx(tx)
	if err := fn(ctx, storedb.New(tx)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func erasureRequestFromRow(r storedb.ErasureRequest) (*store.ErasureRequest, error) {
	out := &store.ErasureRequest{
		ID: r.ID, AccountID: r.AccountID, Actor: r.Actor, CanceledBy: r.CanceledBy, Reason: r.Reason,
		State: store.ErasureState(r.State), ConfirmExpiresAt: r.ConfirmExpiresAt, WalletAddressCount: len(r.WalletAddresses),
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
// withdrawals that are not terminal, wait for a confirmed-rejection refund,
// or were paid within stripePayoutBounceWindow (a bank can still return
// them), and Global Payouts that are pending, processing, or posted recently enough
// that the reconciler still reads them.
func openWithdrawals(ctx context.Context, q *storedb.Queries, accountID string, now time.Time) (int64, error) {
	stripe, err := q.CountOpenStripeWithdrawals(ctx, storedb.CountOpenStripeWithdrawalsParams{
		AccountID: accountID, RefundPrefix: store.StripeConfirmedRejectionPrefix, PaidAfter: now.Add(-erasure.StripePayoutBounceWindow),
	})
	if err != nil {
		return 0, err
	}
	global, err := q.CountOpenGlobalPayouts(ctx, storedb.CountOpenGlobalPayoutsParams{AccountID: accountID, PostedAfter: now.Add(-erasure.GlobalPayoutReconcileWindow)})
	if err != nil {
		return 0, err
	}
	return stripe + global, nil
}

// PlanAccountErasure is a read-only dry run.
func (s *PostgresStore) PlanAccountErasure(ctx context.Context, accountID string, walletAddresses []string) (*store.ErasurePlan, error) {
	var plan *store.ErasurePlan
	err := s.erasureTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(ctx context.Context, q *storedb.Queries) error {
		user, err := q.GetUserForErasurePlan(ctx, accountID)
		if noRows(err) {
			return store.ErrNotFound
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
		plan = &store.ErasurePlan{AccountID: accountID, Email: user.Email, StripeObjects: k.StripeObjects()}
		plan.Rows, plan.Retained, plan.OpenWithdrawals = rows, k.Retained(), open
		if plan.Wallets, err = walletCounts(ctx, q, k.Wallets); err != nil {
			return err
		}
		plan.StripeObjectCounts = erasure.StripeObjectCounts(plan.StripeObjects)
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
func (s *PostgresStore) SaveErasurePlan(ctx context.Context, accountID, actor string, counts store.ErasureCounts, walletAddresses []string, confirmToken string, expiresAt time.Time) (*store.ErasureRequest, error) {
	walletHash := erasure.WalletHash(walletAddresses)
	raw, err := json.Marshal(store.ErasureSummary{Planned: &counts})
	if err != nil {
		return nil, err
	}
	var id string
	err = s.erasureTx(ctx, pgx.TxOptions{}, func(ctx context.Context, q *storedb.Queries) error {
		if _, err := q.LockLiveUserForErasure(ctx, accountID); noRows(err) {
			return store.ErrNotFound
		} else if err != nil {
			return err
		}
		open, err := q.GetOpenErasureRequestForUpdate(ctx, accountID)
		switch {
		case noRows(err):
			id = uuid.NewString()
			return q.InsertErasurePlan(ctx, storedb.InsertErasurePlanParams{
				ID: id, AccountID: accountID, Actor: actor, Plan: raw,
				ConfirmTokenHash: erasure.TokenHash(confirmToken), ConfirmExpiresAt: &expiresAt, WalletHash: walletHash,
			})
		case err != nil:
			return err
		case open.State != string(store.ErasurePlanned):
			return store.ErrErasureConflict
		}
		id = open.ID
		return q.UpdateErasurePlan(ctx, storedb.UpdateErasurePlanParams{
			ID: id, Actor: actor, Plan: raw, ConfirmTokenHash: erasure.TokenHash(confirmToken), ConfirmExpiresAt: &expiresAt,
			WalletHash: walletHash,
		})
	})
	if isUniqueViolation(err) {
		return nil, store.ErrErasureConflict
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

// RequestAccountErasure soft deletes the account after checking the token
// and the email.
func (s *PostgresStore) RequestAccountErasure(ctx context.Context, in store.ErasureConfirm) (*store.ErasureRequest, error) {
	var id string
	err := s.erasureTx(ctx, pgx.TxOptions{}, func(ctx context.Context, q *storedb.Queries) error {
		// Lock order for every erasure step: users, then erasure_requests.
		user, err := q.LockUserForErasure(ctx, in.AccountID)
		if noRows(err) {
			return store.ErrNotFound
		}
		if err != nil {
			return err
		}
		open, err := q.GetOpenErasureRequestForUpdate(ctx, in.AccountID)
		if noRows(err) {
			if user.DeletedAt != nil {
				return store.ErrErasureConflict
			}
			return store.ErrErasureConfirmToken
		}
		if err != nil {
			return err
		}
		if open.State != string(store.ErasurePlanned) || user.DeletedAt != nil {
			return store.ErrErasureConflict
		}
		if !erasure.TokenValid(open.ConfirmTokenHash, open.ConfirmExpiresAt, in.ConfirmToken, in.Now) {
			return store.ErrErasureConfirmToken
		}
		if erasure.NormalizeEmail(user.Email) != erasure.NormalizeEmail(in.Email) {
			return store.ErrErasureEmailMismatch
		}
		if open.WalletHash != erasure.WalletHash(in.WalletAddresses) {
			return store.ErrErasureWalletMismatch
		}
		if err := lockErasurePayments(ctx, q, in.AccountID); err != nil {
			return err
		}
		if n, err := openWithdrawals(ctx, q, in.AccountID, in.Now); err != nil {
			return err
		} else if n > 0 {
			return store.ErrErasureOpenWithdrawal
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
			ID: id, Actor: in.Actor, Reason: in.Reason, WalletAddresses: erasure.NormalizeWallets(in.WalletAddresses),
			RequestedAt: &now, ScrubAfter: &scrubAfter,
		})
	})
	if err != nil {
		return nil, err
	}
	return s.getErasureRequest(ctx, id)
}

// CancelAccountErasure restores the user and providers of a pending request.
func (s *PostgresStore) CancelAccountErasure(ctx context.Context, accountID, actor string, now time.Time) (*store.ErasureRequest, error) {
	var id string
	err := s.erasureTx(ctx, pgx.TxOptions{}, func(ctx context.Context, q *storedb.Queries) error {
		if _, err := q.LockUserForErasure(ctx, accountID); noRows(err) {
			return store.ErrNotFound
		} else if err != nil {
			return err
		}
		open, err := q.GetOpenErasureRequestForUpdate(ctx, accountID)
		if noRows(err) {
			return store.ErrNotFound
		}
		if err != nil {
			return err
		}
		if open.State != string(store.ErasurePending) || open.ScrubAfter == nil || !now.Before(*open.ScrubAfter) {
			return store.ErrErasureConflict
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
func (s *PostgresStore) ScrubAccount(ctx context.Context, requestID string, now time.Time) (*store.ErasureResult, error) {
	var result store.ErasureResult
	err := s.erasureTx(ctx, pgx.TxOptions{}, func(ctx context.Context, q *storedb.Queries) error {
		// Shared identity ownership is evaluated one scrub at a time, so two
		// accounts cannot each retain an identity while the other is erasing.
		if err := q.LockErasureIdentityCleanup(ctx); err != nil {
			return err
		}
		// Lock order: user, request, billing sessions, withdrawals, recipient,
		// balance. Admission takes the user fence first; settlements may
		// finish under their existing withdrawal-before-balance order.
		peek, err := q.GetErasureRequest(ctx, requestID)
		if noRows(err) {
			return store.ErrNotFound
		}
		if err != nil {
			return err
		}
		user, err := q.LockUserForErasure(ctx, peek.AccountID)
		if noRows(err) {
			return store.ErrNotFound
		}
		if err != nil {
			return err
		}
		req, err := q.GetErasureRequestForUpdate(ctx, requestID)
		if err != nil {
			return err
		}
		if req.State != string(store.ErasurePending) || user.DeletedAt == nil {
			return store.ErrErasureConflict
		}
		if err := lockErasurePayments(ctx, q, req.AccountID); err != nil {
			return err
		}
		if n, err := openWithdrawals(ctx, q, req.AccountID, now); err != nil {
			return err
		} else if n > 0 {
			return store.ErrErasureOpenWithdrawal
		}
		// Freeze personal writers before collecting their identity links. A write
		// already admitted must be included in this scrub, not just wait for it.
		if err := q.LockErasureObservations(ctx); err != nil {
			return err
		}
		k, err := collectErasureKeys(ctx, q, req.AccountID, user.StripeAccountID, req.WalletAddresses)
		if err != nil {
			return err
		}
		applied := store.ErasureCounts{Retained: k.Retained()}
		if applied.BalanceMicroUSD, applied.WithdrawableMicroUSD, err = forfeitBalance(ctx, q, req.AccountID, req.ID); err != nil {
			return err
		}
		if applied.Rows, err = applyRules(ctx, q, k); err != nil {
			return err
		}
		if err := q.DeleteStagedErasureObjects(ctx, req.AccountID); err != nil {
			return err
		}
		outbox := k.OutboxRows()
		applied.StripeObjectCounts = erasure.StripeObjectCounts(k.StripeObjects())
		for _, o := range outbox {
			if err := q.InsertErasureOutbox(ctx, storedb.InsertErasureOutboxParams{
				ID: o.ID, RequestID: req.ID, Target: string(o.Target), ExternalID: o.ExternalID, NextAt: now,
			}); err != nil {
				return err
			}
		}
		summary := store.ErasureSummary{Applied: &applied}
		if len(req.Plan) > 0 {
			var stored store.ErasureSummary
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
		return 0, 0, fmt.Errorf("%w: balances counted 1, changed %d", store.ErrErasureCountMismatch, n)
	}
	if err := q.InsertErasureLedgerEntry(ctx, storedb.InsertErasureLedgerEntryParams{
		AccountID: accountID, EntryType: string(store.LedgerErasureForfeit),
		AmountMicroUsd: -bal.BalanceMicroUsd, Reference: "erasure:" + requestID,
	}); err != nil {
		return 0, 0, err
	}
	return bal.BalanceMicroUsd, bal.WithdrawableMicroUsd, nil
}

func (s *PostgresStore) getErasureRequest(ctx context.Context, id string) (*store.ErasureRequest, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	row, err := s.queries().GetErasureRequest(ctx, id)
	if noRows(err) {
		return nil, store.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return erasureRequestFromRow(row)
}

// GetAccountErasure returns the newest request and its outbox rows.
func (s *PostgresStore) GetAccountErasure(ctx context.Context, accountID string) (*store.ErasureRequest, []store.ErasureOutboxItem, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	q := s.queries()
	row, err := q.GetLatestErasureRequest(ctx, accountID)
	if noRows(err) {
		return nil, nil, store.ErrNotFound
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
	items := make([]store.ErasureOutboxItem, 0, len(rows))
	for _, r := range rows {
		items = append(items, store.ErasureOutboxItem{
			ID: r.ID, RequestID: r.RequestID, Target: store.ErasureTarget(r.Target), State: store.ErasureOutboxState(r.State),
			Attempts: int(r.Attempts), NextAt: r.NextAt, LastError: r.LastError, DoneAt: r.DoneAt,
			HasExternalID: r.ExternalID != "", ExternalID: r.ExternalID, CreatedAt: r.CreatedAt,
			HasStripeJob: r.StripeJobID != "", StripeJobID: r.StripeJobID,
			JobStatus: r.StripeJobStatus, JobStatusSince: r.StripeJobStatusSince, JobGeneration: int(r.StripeJobGeneration), LeaseGeneration: r.LeaseGeneration,
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

// walletCounts counts the rows that hold each planned wallet address.
func walletCounts(ctx context.Context, q *storedb.Queries, wallets []erasure.WalletReplacement) ([]store.ErasureWalletCount, error) {
	out := make([]store.ErasureWalletCount, 0, len(wallets))
	for _, w := range wallets {
		c := store.ErasureWalletCount{Address: w.Address}
		var err error
		if c.PaymentsConsumerRows, err = q.CountPaymentConsumerAddress(ctx, w.Address); err != nil {
			return nil, err
		}
		if c.PaymentsProviderRows, err = q.CountPaymentProviderAddress(ctx, w.Address); err != nil {
			return nil, err
		}
		if c.ProviderPayoutRows, err = q.CountProviderPayoutAddress(ctx, w.Address); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, nil
}

// ListErasureRefusedCredits returns credits refused after the erasure.
func (s *PostgresStore) ListErasureRefusedCredits(ctx context.Context, accountID string) ([]store.ErasureRefusedCredit, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rows, err := s.queries().ListErasureRefusedCredits(ctx, accountID)
	if err != nil {
		return nil, err
	}
	out := make([]store.ErasureRefusedCredit, 0, len(rows))
	for _, r := range rows {
		out = append(out, store.ErasureRefusedCredit{ID: r.ID, AccountID: r.AccountID, EntryType: store.LedgerEntryType(r.EntryType),
			AmountMicroUSD: r.AmountMicroUsd, Reference: r.Reference, CreatedAt: r.CreatedAt})
	}
	return out, nil
}
