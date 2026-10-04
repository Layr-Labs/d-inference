package store

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
)

// memoryErasureRequest is a request plus the fields ErasureRequest hides.
type memoryErasureRequest struct {
	ErasureRequest
	tokenHash  string
	walletHash string
	wallets    []string
	leaseUntil time.Time
}

var _ AccountErasureStore = (*MemoryStore)(nil)

func (r *memoryErasureRequest) copyOut() *ErasureRequest {
	out := r.ErasureRequest
	out.WalletAddressCount = len(r.wallets)
	return &out
}

// openErasureLocked returns the planned or pending request of the account.
func (s *MemoryStore) openErasureLocked(accountID string) *memoryErasureRequest {
	for _, r := range s.erasureRequests {
		if r.AccountID == accountID && (r.State == ErasurePlanned || r.State == ErasurePending) {
			return r
		}
	}
	return nil
}

func (s *MemoryStore) openWithdrawalsLocked(accountID string, now time.Time) int64 {
	var n int64
	for _, id := range s.stripeWithdrawalsByAccount[accountID] {
		w := s.stripeWithdrawalsByID[id]
		if w != nil && (w.Status == "pending" || w.Status == "transferred" || StripeRefundRecoverable(w) ||
			(w.Status == "paid" && w.UpdatedAt.After(now.Add(-stripePayoutBounceWindow)))) {
			n++
		}
	}
	for _, p := range s.globalPayouts {
		if p.AccountID != accountID {
			continue
		}
		if p.Status == "pending" || p.Status == "processing" ||
			(p.Status == "posted" && p.SubmittedAt.After(now.Add(-globalPayoutReconcileWindow))) {
			n++
		}
	}
	return n
}

// collectErasureKeysLocked mirrors collectErasureKeys over the memory maps.
func (s *MemoryStore) collectErasureKeysLocked(u *User, wallets []string) *erasureKeys {
	account := u.AccountID
	k := newErasureKeys(account, wallets)
	var seKeys, serials []string
	for _, p := range s.providerRecords {
		if p.AccountID == account {
			k.ProviderIDs = append(k.ProviderIDs, p.ID)
			seKeys = append(seKeys, p.SEPublicKey)
			serials = append(serials, p.SerialNumber)
		}
	}
	for _, ps := range s.providerSessions {
		if ps.AccountID == account {
			serials = append(serials, ps.SerialNumber)
		}
	}
	if inv := s.machineInventory; inv != nil {
		for _, o := range inv.sessions {
			if o.AccountID == account {
				serials = append(serials, o.VerifiedSerial)
			}
		}
	}
	k.ProviderIDs, k.SEKeys, k.Serials = sortedUnique(k.ProviderIDs), sortedUnique(seKeys), sortedUnique(serials)
	ownKeys := stringSet(k.SEKeys)
	var sharedSE []string
	for _, p := range s.providerRecords {
		if p.AccountID != account && ownKeys[p.SEPublicKey] {
			sharedSE = append(sharedSE, p.SEPublicKey)
		}
	}
	k.SEKeys, k.SharedSEKeys = withoutKeys(k.SEKeys, sortedUnique(sharedSE))
	providers := stringSet(k.ProviderIDs)
	var keyIDs []string
	for _, e := range s.appAttestEvidence {
		if providers[e.Evidence.SessionID] {
			keyIDs = append(keyIDs, e.Evidence.KeyID)
		}
	}
	k.AppAttestKeyIDs = sortedUnique(keyIDs)
	ownAppKeys := stringSet(k.AppAttestKeyIDs)
	var sharedApp []string
	for _, e := range s.appAttestEvidence {
		if ownAppKeys[e.Evidence.KeyID] && !providers[e.Evidence.SessionID] {
			sharedApp = append(sharedApp, e.Evidence.KeyID)
		}
	}
	k.AppAttestKeyIDs, k.SharedAppAttestKeys = withoutKeys(k.AppAttestKeyIDs, sortedUnique(sharedApp))
	stripeAccounts := []string{u.StripeAccountID}
	for _, id := range s.stripeWithdrawalsByAccount[account] {
		if w := s.stripeWithdrawalsByID[id]; w != nil {
			stripeAccounts = append(stripeAccounts, w.StripeAccountID)
		}
	}
	k.StripeAccountIDs = sortedUnique(stripeAccounts)
	if r := s.referrersByAccount[account]; r != nil {
		k.ReferrerCode = r.Code
	}
	var sessions []*BillingSession
	for _, b := range s.billingSessions {
		if b.AccountID == account && b.PaymentMethod == "stripe" && b.ExternalID != "" {
			sessions = append(sessions, b)
		}
	}
	sort.Slice(sessions, func(i, j int) bool {
		if !sessions[i].CreatedAt.Equal(sessions[j].CreatedAt) {
			return sessions[i].CreatedAt.Before(sessions[j].CreatedAt)
		}
		return sessions[i].ID < sessions[j].ID
	})
	for _, b := range sessions {
		k.CheckoutSessionIDs = append(k.CheckoutSessionIDs, b.ExternalID)
	}
	var recipients []string
	if r, ok := s.globalRecipients[account]; ok {
		recipients = append(recipients, r.RecipientID)
	}
	for _, p := range s.globalPayouts {
		if p.AccountID == account {
			recipients = append(recipients, p.RecipientID)
		}
	}
	k.RecipientIDs = sortedUnique(recipients)
	if inv := s.machineInventory; inv != nil {
		digests := map[string]bool{}
		for _, serial := range k.Serials {
			digests[mdaSerialDigest(serial)] = true
		}
		for alias, machine := range inv.aliases {
			if alias.Kind != "mda_serial" || alias.Scope != "" || !digests[alias.Digest] {
				continue
			}
			if s.machineSharedLocked(machine, account) {
				k.MDADigestsShared++
			} else {
				k.MDADigestsToDelete = append(k.MDADigestsToDelete, alias.Digest)
			}
		}
		sort.Strings(k.MDADigestsToDelete)
	}
	return k
}

// machineSharedLocked reports whether another account has a session on machine.
func (s *MemoryStore) machineSharedLocked(machine, account string) bool {
	for sid, o := range s.machineInventory.sessions {
		if o.AccountID != account && s.machineInventory.sessionMachines[sid] == machine {
			return true
		}
	}
	return false
}

func stringSet(values []string) map[string]bool {
	out := make(map[string]bool, len(values))
	for _, v := range values {
		out[v] = true
	}
	return out
}

func (s *MemoryStore) PlanAccountErasure(ctx context.Context, accountID string, walletAddresses []string) (*ErasurePlan, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	u := s.usersByAccountID[accountID]
	if u == nil {
		return nil, ErrNotFound
	}
	k := s.collectErasureKeysLocked(u, walletAddresses)
	rows, err := s.runMemoryRulesLocked(k, time.Now(), false)
	if err != nil {
		return nil, err
	}
	plan := &ErasurePlan{AccountID: accountID, Email: u.Email, StripeObjects: k.stripeObjects()}
	plan.Rows, plan.Retained = rows, k.retained()
	plan.StripeObjectCounts = stripeObjectCounts(plan.StripeObjects)
	plan.OpenWithdrawals = s.openWithdrawalsLocked(accountID, time.Now())
	for _, w := range k.Wallets {
		plan.Wallets = append(plan.Wallets, ErasureWalletCount{Address: w.Address})
	}
	plan.BalanceMicroUSD, plan.WithdrawableMicroUSD = s.balances[accountID], s.withdrawable[accountID]
	return plan, nil
}

func (s *MemoryStore) SaveErasurePlan(ctx context.Context, accountID, actor string, counts ErasureCounts, walletAddresses []string, confirmToken string, expiresAt time.Time) (*ErasureRequest, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if u := s.usersByAccountID[accountID]; u == nil || u.DeletedAt != nil {
		return nil, ErrNotFound
	}
	r := s.openErasureLocked(accountID)
	if r != nil && r.State != ErasurePlanned {
		return nil, ErrErasureConflict
	}
	if r == nil {
		r = &memoryErasureRequest{ErasureRequest: ErasureRequest{ID: uuid.NewString(), AccountID: accountID, State: ErasurePlanned, CreatedAt: time.Now()}}
		s.erasureRequests[r.ID] = r
	}
	exp := expiresAt
	r.Actor, r.Summary, r.tokenHash, r.ConfirmExpiresAt = actor, ErasureSummary{Planned: &counts}, erasureTokenHash(confirmToken), &exp
	r.walletHash = erasureWalletHash(walletAddresses)
	return r.copyOut(), nil
}

func (s *MemoryStore) RequestAccountErasure(ctx context.Context, in ErasureConfirm) (*ErasureRequest, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.openErasureLocked(in.AccountID)
	if r == nil {
		return nil, ErrErasureConfirmToken
	}
	if r.State != ErasurePlanned {
		return nil, ErrErasureConflict
	}
	if !erasureTokenValid(r.tokenHash, r.ConfirmExpiresAt, in.ConfirmToken, in.Now) {
		return nil, ErrErasureConfirmToken
	}
	u := s.usersByAccountID[in.AccountID]
	if u == nil || u.DeletedAt != nil {
		return nil, ErrNotFound
	}
	if normalizeErasureEmail(u.Email) != normalizeErasureEmail(in.Email) {
		return nil, ErrErasureEmailMismatch
	}
	if r.walletHash != erasureWalletHash(in.WalletAddresses) {
		return nil, ErrErasureWalletMismatch
	}
	if s.openWithdrawalsLocked(in.AccountID, in.Now) > 0 {
		return nil, ErrErasureOpenWithdrawal
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
	r.State, r.Actor, r.Reason, r.wallets = ErasurePending, in.Actor, in.Reason, normalizeWallets(in.WalletAddresses)
	r.RequestedAt, r.ScrubAfter, r.tokenHash, r.ConfirmExpiresAt = &now, &scrubAfter, "", nil
	return r.copyOut(), nil
}

func (s *MemoryStore) CancelAccountErasure(ctx context.Context, accountID, actor string, now time.Time) (*ErasureRequest, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.openErasureLocked(accountID)
	if r == nil {
		return nil, ErrNotFound
	}
	if r.State != ErasurePending || r.ScrubAfter == nil || !now.Before(*r.ScrubAfter) {
		return nil, ErrErasureConflict
	}
	u := s.usersByAccountID[accountID]
	if u == nil {
		return nil, ErrNotFound
	}
	if other := s.usersByPrivyID[u.PrivyUserID]; other != nil && other != u && other.DeletedAt == nil {
		return nil, fmt.Errorf("store: restore user: Privy ID %q is held by another live user", u.PrivyUserID)
	}
	u.DeletedAt = nil
	s.usersByPrivyID[u.PrivyUserID] = u
	for _, p := range s.providerRecords {
		if p.AccountID == accountID {
			p.DeletedAt = nil
		}
	}
	at := now
	r.State, r.CanceledBy, r.CanceledAt, r.wallets, r.leaseUntil = ErasureCanceled, actor, &at, nil, time.Time{}
	return r.copyOut(), nil
}

func (s *MemoryStore) ScrubAccount(ctx context.Context, requestID string, now time.Time) (*ErasureResult, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	r := s.erasureRequests[requestID]
	if r == nil {
		return nil, ErrNotFound
	}
	if r.State != ErasurePending {
		return nil, ErrErasureConflict
	}
	u := s.usersByAccountID[r.AccountID]
	if u == nil {
		return nil, ErrNotFound
	}
	if u.DeletedAt == nil {
		return nil, ErrErasureConflict
	}
	if s.openWithdrawalsLocked(r.AccountID, now) > 0 {
		return nil, ErrErasureOpenWithdrawal
	}
	k := s.collectErasureKeysLocked(u, r.wallets)
	applied := ErasureCounts{Retained: k.retained(), StripeObjectCounts: stripeObjectCounts(k.stripeObjects())}
	applied.BalanceMicroUSD, applied.WithdrawableMicroUSD = s.balances[r.AccountID], s.withdrawable[r.AccountID]
	if applied.BalanceMicroUSD != 0 || applied.WithdrawableMicroUSD != 0 {
		s.creditLocked(r.AccountID, -applied.BalanceMicroUSD, LedgerErasureForfeit, "erasure:"+r.ID, now)
		s.withdrawable[r.AccountID] = 0
	}
	rows, err := s.runMemoryRulesLocked(k, now, true)
	if err != nil {
		return nil, err
	}
	applied.Rows = rows
	for _, o := range k.outboxRows() {
		o.RequestID, o.NextAt, o.CreatedAt, o.HasExternalID = r.ID, now, now, o.ExternalID != ""
		s.erasureOutbox = append(s.erasureOutbox, o)
	}
	at := now
	r.State, r.ErasedAt, r.wallets, r.leaseUntil, r.LastError = ErasureErased, &at, nil, time.Time{}, ""
	r.Summary.Applied = &applied
	s.erasedAccounts[r.AccountID] = true
	return &ErasureResult{Request: r.copyOut(), SEKeys: k.SEKeys, ProviderIDs: k.ProviderIDs}, nil
}

func (s *MemoryStore) GetAccountErasure(ctx context.Context, accountID string) (*ErasureRequest, []ErasureOutboxItem, error) {
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
		return nil, nil, ErrNotFound
	}
	items := []ErasureOutboxItem{}
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
		if r.State == ErasurePending && r.ScrubAfter != nil && !r.ScrubAfter.After(now) && !r.leaseUntil.After(now) {
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
	if r := s.erasureRequests[requestID]; r != nil && r.State == ErasurePending {
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

func (s *MemoryStore) ListErasureRefusedCredits(ctx context.Context, accountID string) ([]ErasureRefusedCredit, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := []ErasureRefusedCredit{}
	for _, c := range s.erasureRefusedCredits {
		if c.AccountID == accountID {
			out = append(out, c)
		}
	}
	return out, nil
}

// refuseErasedCreditLocked records and refuses a credit to an erased
// account, as the Postgres triggers in 00021_erasure_refuse_credits.sql do.
func (s *MemoryStore) refuseErasedCreditLocked(accountID string, amount int64, entryType LedgerEntryType, reference string, at time.Time) bool {
	if amount <= 0 || !s.erasedAccounts[accountID] {
		return false
	}
	switch {
	case entryType == LedgerAdminCredit || entryType == LedgerAdminReward:
		reference = string(entryType)
	case strings.HasPrefix(reference, "stripe:"):
		reference = "stripe:erased"
	}
	s.erasureRefusedSeq++
	s.erasureRefusedCredits = append(s.erasureRefusedCredits, ErasureRefusedCredit{
		ID: s.erasureRefusedSeq, AccountID: accountID, EntryType: entryType, AmountMicroUSD: amount, Reference: reference, CreatedAt: at,
	})
	return true
}
