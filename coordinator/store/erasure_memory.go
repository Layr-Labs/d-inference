package store

import (
	"context"
	"encoding/json"
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
	k := &erasureKeys{
		AccountID: account, ConsumerKeyHash: hashKey(account),
		PrivyReplacement: erasedValue("erased:"), ReferrerReplacement: erasedValue("erased-"),
	}
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
	for _, w := range normalizeWallets(wallets) {
		k.Wallets = append(k.Wallets, walletReplacement{Address: w, Replacement: erasedValue("erased-")})
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

// memoryRule counts the items a rule links to the account and, when apply
// is set, changes them. The memory store holds no rows for the rules mapped
// to memoryNoTable.
type memoryRule func(s *MemoryStore, k *erasureKeys, now time.Time, apply bool) int64

func memoryNoTable(*MemoryStore, *erasureKeys, time.Time, bool) int64 { return 0 }

// memoryErasureRules maps every rule name in erasureRules to its memory
// form. TestMemoryErasureRulesCoverRuleTable keeps the two in step.
var memoryErasureRules = map[string]memoryRule{
	"users": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		u := s.usersByAccountID[k.AccountID]
		if u == nil {
			return 0
		}
		if apply {
			if s.usersByPrivyID[u.PrivyUserID] == u {
				delete(s.usersByPrivyID, u.PrivyUserID)
			}
			if u.StripeAccountID != "" && s.usersByStripeAccountID[u.StripeAccountID] == u {
				delete(s.usersByStripeAccountID, u.StripeAccountID)
			}
			u.Email, u.PrivyUserID = "", k.PrivyReplacement
			u.StripeAccountID, u.StripeAccountStatus, u.StripeAccountCountry = "", "", ""
			u.StripeDestinationType, u.StripeDestinationLast4, u.StripeInstantEligible = "", "", false
			s.usersByPrivyID[u.PrivyUserID] = u
		}
		return 1
	},
	"api_keys": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for _, rec := range s.keyRecords {
			if rec.OwnerAccountID == k.AccountID {
				n++
				if apply {
					rec.Name = ""
				}
			}
		}
		return n
	},
	"provider_tokens": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for _, pt := range s.providerTokens {
			if pt.AccountID == k.AccountID {
				n++
				if apply {
					pt.Label = ""
				}
			}
		}
		return n
	},
	"device_codes": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for code, dc := range s.deviceCodesByCode {
			if dc.AccountID == k.AccountID {
				n++
				if apply {
					delete(s.deviceCodesByCode, code)
					delete(s.deviceCodesByUserCode, dc.UserCode)
				}
			}
		}
		return n
	},
	"providers": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for _, p := range s.providerRecords {
			if p.AccountID == k.AccountID {
				n++
				if apply {
					p.SerialNumber, p.Location, p.AttestationResult, p.MDACertChain = "", nil, nil, nil
				}
			}
		}
		return n
	},
	"provider_sessions": func(s *MemoryStore, k *erasureKeys, now time.Time, apply bool) int64 {
		var n int64
		for i := range s.providerSessions {
			ps := &s.providerSessions[i]
			if ps.AccountID == k.AccountID {
				n++
				if apply {
					ps.SerialNumber = ""
					if ps.DisconnectedAt == nil {
						t := now
						ps.DisconnectedAt = &t
					}
				}
			}
		}
		if apply && s.machineInventory != nil {
			// Memory keeps the verified serial on the observation itself;
			// Postgres never stores it (json:"-").
			for sid, o := range s.machineInventory.sessions {
				if o.AccountID == k.AccountID {
					o.VerifiedSerial = ""
					s.machineInventory.sessions[sid] = o
				}
			}
		}
		return n
	},
	"provider_log_reports": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		kept := s.logReports[:0:0]
		for _, r := range s.logReports {
			if r.AccountID == k.AccountID {
				n++
				continue
			}
			kept = append(kept, r)
		}
		if apply {
			s.logReports = kept
		}
		return n
	},
	"provider_trust_reuse": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for _, key := range k.SEKeys {
			if _, ok := s.providerTrustReuse[key]; ok {
				n++
				if apply {
					delete(s.providerTrustReuse, key)
				}
			}
		}
		return n
	},
	"provider_verification_jobs": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		keys := stringSet(k.SEKeys)
		var n int64
		for id, job := range s.verificationJobs {
			if keys[job.SEPubKey] {
				n++
				if apply {
					delete(s.verificationJobs, id)
				}
			}
		}
		return n
	},
	"code_attestations": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for _, key := range k.SEKeys {
			if _, ok := s.codeAttestations[key]; ok {
				n++
				if apply {
					delete(s.codeAttestations, key)
				}
			}
		}
		return n
	},
	"code_attest_push_budgets": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		keys := stringSet(k.SEKeys)
		var n int64
		for id, b := range s.codeAttestPushBudgets {
			if keys[b.SEPubKey] {
				n++
				if apply {
					delete(s.codeAttestPushBudgets, id)
				}
			}
		}
		return n
	},
	"machine_aliases_account": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		if s.machineInventory == nil {
			return 0
		}
		var n int64
		for alias := range s.machineInventory.aliases {
			if (alias.Kind == "app_attest" || alias.Kind == "legacy_se") && alias.Scope == k.AccountID {
				n++
				if apply {
					delete(s.machineInventory.aliases, alias)
				}
			}
		}
		return n
	},
	"machine_aliases_mda_serial": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		if s.machineInventory == nil {
			return 0
		}
		var n int64
		for _, digest := range k.MDADigestsToDelete {
			alias := machineAlias{Kind: "mda_serial", Digest: digest}
			if _, ok := s.machineInventory.aliases[alias]; ok {
				n++
				if apply {
					delete(s.machineInventory.aliases, alias)
				}
			}
		}
		return n
	},
	"app_attest_evidence_blobs": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		providers := stringSet(k.ProviderIDs)
		var n int64
		for id, e := range s.appAttestEvidence {
			if providers[e.Evidence.SessionID] {
				n++
				if apply {
					e.Evidence.Proof, e.Evidence.ProofField = nil, ""
					if e.Decision.Receipt != nil {
						r := *e.Decision.Receipt
						r.Body, r.ResponseBody, r.Context = nil, nil, json.RawMessage(`{}`)
						e.Decision.Receipt = &r
					}
					s.appAttestEvidence[id] = e
				}
			}
		}
		return n
	},
	"app_attest_evidence": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		providers := stringSet(k.ProviderIDs)
		var n int64
		for id, e := range s.appAttestEvidence {
			if providers[e.Evidence.SessionID] {
				n++
				if apply {
					e.Evidence.Context = json.RawMessage(`{}`)
					s.appAttestEvidence[id] = e
				}
			}
		}
		return n
	},
	"app_attest_receipt_jobs":  memoryNoTable,
	"app_attest_receipt_blobs": memoryNoTable,
	"app_attest_receipts":      memoryNoTable,
	"usage_request_location": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for i := range s.usage {
			// The memory store keeps the raw consumer key; Postgres keeps its hash.
			if s.usage[i].ConsumerKey == k.AccountID && s.usage[i].RequestLocation != nil {
				n++
				if apply {
					s.usage[i].RequestLocation = nil
				}
			}
		}
		return n
	},
	"inference_routes_consumer_region": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for i := range s.inferenceRoutes {
			if s.inferenceRoutes[i].ConsumerKeyHash == k.ConsumerKeyHash && s.inferenceRoutes[i].ConsumerRegion != "" {
				n++
				if apply {
					s.inferenceRoutes[i].ConsumerRegion = ""
				}
			}
		}
		return n
	},
	"inference_routes_provider_region": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		providers := stringSet(k.ProviderIDs)
		var n int64
		for i := range s.inferenceRoutes {
			if providers[s.inferenceRoutes[i].ProviderID] && s.inferenceRoutes[i].ProviderRegion != "" {
				n++
				if apply {
					s.inferenceRoutes[i].ProviderRegion = ""
				}
			}
		}
		return n
	},
	"referrers": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		r := s.referrersByAccount[k.AccountID]
		if r == nil {
			return 0
		}
		if apply {
			old := r.Code
			delete(s.referrersByCode, old)
			r.Code = k.ReferrerReplacement
			s.referrersByCode[r.Code] = r
			if c, ok := s.referralCounts[old]; ok {
				delete(s.referralCounts, old)
				s.referralCounts[r.Code] = c
			}
			for referred, code := range s.referrals {
				if code == old {
					s.referrals[referred] = r.Code
				}
			}
		}
		return 1
	},
	"billing_sessions_referral_code": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		if k.ReferrerCode == "" {
			return 0
		}
		var n int64
		for _, b := range s.billingSessions {
			if b.ReferralCode == k.ReferrerCode {
				n++
				if apply {
					b.ReferralCode = k.ReferrerReplacement
				}
			}
		}
		return n
	},
	"billing_sessions": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for _, b := range s.billingSessions {
			if b.AccountID == k.AccountID {
				n++
				if apply {
					b.ExternalID = ""
					if b.Status == "pending" {
						b.Status = "erased"
					}
				}
			}
		}
		return n
	},
	"ledger_entries_stripe_reference": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for i := range s.ledgerEntries {
			e := &s.ledgerEntries[i]
			if e.AccountID == k.AccountID && strings.HasPrefix(e.Reference, "stripe:") {
				n++
				if apply {
					e.Reference = "stripe:erased"
				}
			}
		}
		return n
	},
	"ledger_entries_admin_note": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for i := range s.ledgerEntries {
			e := &s.ledgerEntries[i]
			if e.AccountID == k.AccountID && (e.Type == LedgerAdminCredit || e.Type == LedgerAdminReward) && e.Reference != string(e.Type) {
				n++
				if apply {
					e.Reference = string(e.Type)
				}
			}
		}
		return n
	},
	"global_payout_recipients": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		if _, ok := s.globalRecipients[k.AccountID]; !ok {
			return 0
		}
		if apply {
			s.globalRecipients[k.AccountID] = GlobalRecipient{ID: uuid.NewString(), AccountID: k.AccountID}
		}
		return 1
	},
	"global_payout_withdrawals": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for id, p := range s.globalPayouts {
			if p.AccountID == k.AccountID {
				n++
				if apply {
					p.RecipientID, p.PayoutMethodID, p.Request = "", "", json.RawMessage(`{}`)
					s.globalPayouts[id] = p
				}
			}
		}
		return n
	},
	"stripe_withdrawals": func(s *MemoryStore, k *erasureKeys, _ time.Time, apply bool) int64 {
		var n int64
		for _, id := range s.stripeWithdrawalsByAccount[k.AccountID] {
			if w := s.stripeWithdrawalsByID[id]; w != nil {
				n++
				if apply {
					w.StripeAccountID = ""
				}
			}
		}
		return n
	},
	"payments_consumer_address": memoryNoTable,
	"payments_provider_address": memoryNoTable,
	"provider_payouts_address":  memoryNoTable,
}

func (s *MemoryStore) runMemoryRulesLocked(k *erasureKeys, now time.Time, apply bool) ([]ErasureRowCount, error) {
	out := make([]ErasureRowCount, 0, len(erasureRules))
	for _, rule := range erasureRules {
		fn, ok := memoryErasureRules[rule.Name]
		if !ok {
			return nil, fmt.Errorf("store: no memory erasure rule %q", rule.Name)
		}
		out = append(out, ErasureRowCount{
			Rule: rule.Name, Table: rule.Table, Columns: rule.columnNames(), Action: rule.action(),
			Rows: fn(s, k, now, apply),
		})
	}
	return out, nil
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

func (s *MemoryStore) LeaseDueErasureOutbox(ctx context.Context, now time.Time, lease time.Duration, limit int) ([]ErasureOutboxWork, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var due []int
	for i, o := range s.erasureOutbox {
		if o.State == ErasureOutboxPending && !o.NextAt.After(now) && !s.erasureOutboxLease[o.ID].After(now) {
			due = append(due, i)
		}
	}
	sort.Slice(due, func(a, b int) bool { return s.erasureOutbox[due[a]].NextAt.Before(s.erasureOutbox[due[b]].NextAt) })
	out := []ErasureOutboxWork{}
	for _, i := range due {
		if len(out) == limit {
			break
		}
		o := s.erasureOutbox[i]
		s.erasureOutboxLease[o.ID] = now.Add(lease)
		w := ErasureOutboxWork{ErasureOutboxItem: o}
		if r := s.erasureRequests[o.RequestID]; r != nil {
			w.AccountID = r.AccountID
			if r.ErasedAt != nil {
				w.ErasedAt = *r.ErasedAt
			}
		}
		out = append(out, w)
	}
	return out, nil
}

func (s *MemoryStore) SaveErasureOutboxResult(ctx context.Context, id string, r ErasureOutboxResult) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.erasureOutbox {
		o := &s.erasureOutbox[i]
		if o.ID != id {
			continue
		}
		if o.State != ErasureOutboxPending {
			return ErrErasureConflict
		}
		o.State, o.Attempts, o.NextAt, o.LastError, o.StripeJobID = r.State, r.Attempts, r.NextAt, r.LastError, r.StripeJobID
		o.DoneAt = nil
		if r.State == ErasureOutboxDone {
			at := r.NextAt
			o.ExternalID, o.StripeJobID, o.DoneAt = "", "", &at
		}
		o.HasExternalID, o.HasStripeJob = o.ExternalID != "", o.StripeJobID != ""
		delete(s.erasureOutboxLease, id)
		return nil
	}
	return ErrErasureConflict
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
