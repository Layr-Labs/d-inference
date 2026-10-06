package memory

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// memoryErasureRequest is a request plus the fields store.ErasureRequest hides.
type memoryErasureRequest struct {
	store.ErasureRequest
	tokenHash  string
	walletHash string
	wallets    []string
	leaseUntil time.Time
}

var _ store.AccountErasureStore = (*MemoryStore)(nil)

func (r *memoryErasureRequest) copyOut() *store.ErasureRequest {
	out := r.ErasureRequest
	out.WalletAddressCount = len(r.wallets)
	return &out
}

// openErasureLocked returns the planned or pending request of the account.
func (s *MemoryStore) openErasureLocked(accountID string) *memoryErasureRequest {
	for _, r := range s.erasureRequests {
		if r.AccountID == accountID && (r.State == store.ErasurePlanned || r.State == store.ErasurePending) {
			return r
		}
	}
	return nil
}

func (s *MemoryStore) openWithdrawalsLocked(accountID string, now time.Time) int64 {
	var n int64
	for _, id := range s.stripeWithdrawalsByAccount[accountID] {
		w := s.stripeWithdrawalsByID[id]
		if w != nil && (w.Status == "pending" || w.Status == "transferred" || store.StripeRefundRecoverable(w) ||
			(w.Status == "paid" && w.UpdatedAt.After(now.Add(-erasure.StripePayoutBounceWindow)))) {
			n++
		}
	}
	for _, p := range s.globalPayouts {
		if p.AccountID != accountID {
			continue
		}
		if p.Status == "pending" || p.Status == "processing" ||
			(p.Status == "posted" && p.SubmittedAt.After(now.Add(-erasure.GlobalPayoutReconcileWindow))) {
			n++
		}
	}
	return n
}

func (s *MemoryStore) PlanAccountErasure(ctx context.Context, accountID string, walletAddresses []string) (*store.ErasurePlan, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	u := s.usersByAccountID[accountID]
	if u == nil {
		return nil, store.ErrNotFound
	}
	k := s.collectErasureKeysLocked(u, walletAddresses)
	rows, err := s.runMemoryRulesLocked(k, time.Now(), false)
	if err != nil {
		return nil, err
	}
	plan := &store.ErasurePlan{AccountID: accountID, Email: u.Email, StripeObjects: k.StripeObjects()}
	plan.Rows, plan.Retained = rows, k.Retained()
	plan.StripeObjectCounts = erasure.StripeObjectCounts(plan.StripeObjects)
	plan.OpenWithdrawals = s.openWithdrawalsLocked(accountID, time.Now())
	for _, w := range k.Wallets {
		plan.Wallets = append(plan.Wallets, store.ErasureWalletCount{Address: w.Address})
	}
	plan.BalanceMicroUSD, plan.WithdrawableMicroUSD = s.balances[accountID], s.withdrawable[accountID]
	return plan, nil
}

func (s *MemoryStore) SaveErasurePlan(ctx context.Context, accountID, actor string, counts store.ErasureCounts, walletAddresses []string, confirmToken string, expiresAt time.Time) (*store.ErasureRequest, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if u := s.usersByAccountID[accountID]; u == nil || u.DeletedAt != nil {
		return nil, store.ErrNotFound
	}
	r := s.openErasureLocked(accountID)
	if r != nil && r.State != store.ErasurePlanned {
		return nil, store.ErrErasureConflict
	}
	if r == nil {
		r = &memoryErasureRequest{ErasureRequest: store.ErasureRequest{ID: uuid.NewString(), AccountID: accountID, State: store.ErasurePlanned, CreatedAt: time.Now()}}
		s.erasureRequests[r.ID] = r
	}
	exp := expiresAt
	r.Actor, r.Summary, r.tokenHash, r.ConfirmExpiresAt = actor, store.ErasureSummary{Planned: &counts}, erasure.TokenHash(confirmToken), &exp
	r.walletHash = erasure.WalletHash(walletAddresses)
	return r.copyOut(), nil
}

func (s *MemoryStore) RequestAccountErasure(ctx context.Context, in store.ErasureConfirm) (*store.ErasureRequest, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.openErasureLocked(in.AccountID)
	if r == nil {
		return nil, store.ErrErasureConfirmToken
	}
	if r.State != store.ErasurePlanned {
		return nil, store.ErrErasureConflict
	}
	if !erasure.TokenValid(r.tokenHash, r.ConfirmExpiresAt, in.ConfirmToken, in.Now) {
		return nil, store.ErrErasureConfirmToken
	}
	u := s.usersByAccountID[in.AccountID]
	if u == nil || u.DeletedAt != nil {
		return nil, store.ErrNotFound
	}
	if erasure.NormalizeEmail(u.Email) != erasure.NormalizeEmail(in.Email) {
		return nil, store.ErrErasureEmailMismatch
	}
	if r.walletHash != erasure.WalletHash(in.WalletAddresses) {
		return nil, store.ErrErasureWalletMismatch
	}
	if s.openWithdrawalsLocked(in.AccountID, in.Now) > 0 {
		return nil, store.ErrErasureOpenWithdrawal
	}
	now := in.Now
	u.DeletedAt = &now
	for _, p := range s.providerRecords {
		if p.AccountID == in.AccountID && p.DeletedAt == nil {
			p.DeletedAt = &now
		}
	}
	for _, rec := range s.keyRecords {
		if rec.OwnerAccountID == in.AccountID && rec.DeletedAt == nil {
			rec.Disabled, rec.DeletedAt = true, &now
		}
	}
	for _, pt := range s.providerTokens {
		if pt.AccountID == in.AccountID && pt.DeletedAt == nil {
			pt.Active, pt.DeletedAt = false, &now
		}
	}
	scrubAfter := now.Add(in.Grace)
	r.State, r.Actor, r.Reason, r.wallets = store.ErasurePending, in.Actor, in.Reason, erasure.NormalizeWallets(in.WalletAddresses)
	r.RequestedAt, r.ScrubAfter, r.tokenHash, r.ConfirmExpiresAt = &now, &scrubAfter, "", nil
	return r.copyOut(), nil
}

func (s *MemoryStore) CancelAccountErasure(ctx context.Context, accountID, actor string, now time.Time) (*store.ErasureRequest, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.openErasureLocked(accountID)
	if r == nil {
		return nil, store.ErrNotFound
	}
	if r.State != store.ErasurePending || r.ScrubAfter == nil || !now.Before(*r.ScrubAfter) {
		return nil, store.ErrErasureConflict
	}
	u := s.usersByAccountID[accountID]
	if u == nil {
		return nil, store.ErrNotFound
	}
	if other := s.usersByPrivyID[u.PrivyUserID]; other != nil && other != u && other.DeletedAt == nil {
		return nil, fmt.Errorf("store: restore user: Privy ID %q is held by another live user", u.PrivyUserID)
	}
	u.DeletedAt = nil
	s.usersByPrivyID[u.PrivyUserID] = u
	for _, p := range s.providerRecords {
		if p.AccountID == accountID && p.DeletedAt != nil && r.RequestedAt != nil && p.DeletedAt.Equal(*r.RequestedAt) {
			p.DeletedAt = nil
		}
	}
	at := now
	r.State, r.CanceledBy, r.CanceledAt, r.wallets, r.leaseUntil = store.ErasureCanceled, actor, &at, nil, time.Time{}
	return r.copyOut(), nil
}

func (s *MemoryStore) ScrubAccount(ctx context.Context, requestID string, now time.Time) (*store.ErasureResult, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.erasureRequests[requestID]
	if r == nil {
		return nil, store.ErrNotFound
	}
	if r.State != store.ErasurePending {
		return nil, store.ErrErasureConflict
	}
	u := s.usersByAccountID[r.AccountID]
	if u == nil {
		return nil, store.ErrNotFound
	}
	if u.DeletedAt == nil {
		return nil, store.ErrErasureConflict
	}
	if s.openWithdrawalsLocked(r.AccountID, now) > 0 {
		return nil, store.ErrErasureOpenWithdrawal
	}
	s.retainErasureSEOwnersLocked(r.AccountID)
	k := s.collectErasureKeysLocked(u, r.wallets)
	applied := store.ErasureCounts{Retained: k.Retained(), StripeObjectCounts: erasure.StripeObjectCounts(k.StripeObjects())}
	applied.BalanceMicroUSD, applied.WithdrawableMicroUSD = s.balances[r.AccountID], s.withdrawable[r.AccountID]
	if applied.BalanceMicroUSD != 0 || applied.WithdrawableMicroUSD != 0 {
		s.creditLocked(r.AccountID, -applied.BalanceMicroUSD, store.LedgerErasureForfeit, "erasure:"+r.ID, now)
		s.withdrawable[r.AccountID] = 0
	}
	rows, err := s.runMemoryRulesLocked(k, now, true)
	if err != nil {
		return nil, err
	}
	applied.Rows = rows
	kept := s.erasureOutbox[:0]
	for _, item := range s.erasureOutbox {
		previous := s.erasureRequests[item.RequestID]
		if previous != nil && previous.AccountID == r.AccountID && previous.State != store.ErasureErased {
			continue
		}
		kept = append(kept, item)
	}
	s.erasureOutbox = kept
	for _, o := range k.OutboxRows() {
		o.RequestID, o.NextAt, o.CreatedAt, o.HasExternalID = r.ID, now, now, o.ExternalID != ""
		s.erasureOutbox = append(s.erasureOutbox, o)
	}
	at := now
	r.State, r.ErasedAt, r.wallets, r.leaseUntil, r.LastError = store.ErasureErased, &at, nil, time.Time{}, ""
	r.Summary.Applied = &applied
	s.erasedAccounts[r.AccountID] = true
	return &store.ErasureResult{Request: r.copyOut(), SEKeys: k.SEKeys, ProviderIDs: k.ProviderIDs}, nil
}

func (s *MemoryStore) GetAccountErasure(ctx context.Context, accountID string) (*store.ErasureRequest, []store.ErasureOutboxItem, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	var latest *memoryErasureRequest
	for _, r := range s.erasureRequests {
		if r.AccountID == accountID && (latest == nil || r.CreatedAt.After(latest.CreatedAt)) {
			latest = r
		}
	}
	if latest == nil {
		return nil, nil, store.ErrNotFound
	}
	items := []store.ErasureOutboxItem{}
	for _, o := range s.erasureOutbox {
		if o.RequestID == latest.ID {
			items = append(items, o)
		}
	}
	return latest.copyOut(), items, nil
}

func (s *MemoryStore) LeaseDueAccountErasures(ctx context.Context, now time.Time, lease time.Duration, limit int) ([]string, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var due []*memoryErasureRequest
	for _, r := range s.erasureRequests {
		if r.State == store.ErasurePending && r.ScrubAfter != nil && !r.ScrubAfter.After(now) && !r.leaseUntil.After(now) {
			due = append(due, r)
		}
	}
	sort.Slice(due, func(i, j int) bool { return due[i].ScrubAfter.Before(*due[j].ScrubAfter) })
	ids := []string{}
	for _, r := range due {
		if len(ids) == limit {
			break
		}
		r.leaseUntil = now.Add(lease)
		ids = append(ids, r.ID)
	}
	return ids, nil
}

func (s *MemoryStore) RecordAccountErasureFailure(ctx context.Context, requestID, message string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if r := s.erasureRequests[requestID]; r != nil && r.State == store.ErasurePending {
		r.LastError = message
	}
	return nil
}

func (s *MemoryStore) PrivyUserPendingErasure(ctx context.Context, privyUserID string) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, u := range s.usersByAccountID {
		if u.PrivyUserID == privyUserID && u.DeletedAt != nil {
			return true, nil
		}
	}
	return false, nil
}

func (s *MemoryStore) ListErasureRefusedCredits(ctx context.Context, accountID string) ([]store.ErasureRefusedCredit, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []store.ErasureRefusedCredit{}
	for _, c := range s.erasureRefusedCredits {
		if c.AccountID == accountID {
			out = append(out, c)
		}
	}
	return out, nil
}

// refuseErasedCreditLocked records and refuses a credit to an erased
// account, as the Postgres triggers in 00025_erasure_refuse_credits.sql do.
func (s *MemoryStore) refuseErasedCreditLocked(accountID string, amount int64, entryType store.LedgerEntryType, reference string, at time.Time) bool {
	if amount <= 0 || !s.erasedAccounts[accountID] {
		return false
	}
	if s.erasureRefusedIdentities == nil {
		s.erasureRefusedIdentities = make(map[refusedCreditIdentity]bool)
	}
	s.erasureRefusedIdentities[refusedCreditIdentity{accountID, entryType, store.HashKey(reference)}] = true
	switch {
	case entryType == store.LedgerAdminCredit || entryType == store.LedgerAdminReward:
		reference = string(entryType)
	case strings.HasPrefix(reference, "stripe:"):
		reference = "stripe:erased"
	}
	s.erasureRefusedSeq++
	s.erasureRefusedCredits = append(s.erasureRefusedCredits, store.ErasureRefusedCredit{
		ID: s.erasureRefusedSeq, AccountID: accountID, EntryType: entryType, AmountMicroUSD: amount, Reference: reference, CreatedAt: at,
	})
	return true
}

// The audit omits personal references; their hashes preserve once-credit
// identity without changing the behavior of ordinary repeatable credits.
type refusedCreditIdentity struct {
	accountID     string
	entryType     store.LedgerEntryType
	referenceHash string
}
