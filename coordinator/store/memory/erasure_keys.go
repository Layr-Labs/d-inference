package memory

import (
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// collectErasureKeysLocked mirrors collectErasureKeys over the memory maps.
func (s *MemoryStore) collectErasureKeysLocked(u *store.User, wallets []string) *erasure.Keys {
	account := u.AccountID
	k := erasure.NewKeys(account, wallets)
	var seKeys, serials []string
	for _, p := range s.providerRecords {
		if p.AccountID == account {
			k.ProviderIDs = append(k.ProviderIDs, p.ID)
			seKeys = append(seKeys, p.SEPublicKey)
			serials = append(serials, p.SerialNumber)
		}
	}
	for _, ps := range s.history.ProviderSessions {
		if ps.AccountID == account {
			k.ProviderIDs = append(k.ProviderIDs, ps.SessionID)
			serials = append(serials, ps.SerialNumber)
		}
	}
	if inv := s.machineInventory; inv != nil {
		for _, o := range inv.Sessions {
			if o.AccountID == account {
				k.ProviderIDs = append(k.ProviderIDs, o.SessionID)
				serials = append(serials, o.VerifiedSerial)
			}
		}
	}
	k.ProviderIDs, k.SEKeys, k.Serials = erasure.SortedUnique(k.ProviderIDs), erasure.SortedUnique(seKeys), erasure.SortedUnique(serials)
	ownKeys := stringSet(k.SEKeys)
	var sharedSE []string
	for _, p := range s.providerRecords {
		if p.AccountID != account && !s.erasedAccounts[p.AccountID] && ownKeys[p.SEPublicKey] {
			sharedSE = append(sharedSE, p.SEPublicKey)
		}
	}
	k.SEKeys, k.SharedSEKeys = erasure.WithoutKeys(k.SEKeys, erasure.SortedUnique(sharedSE))
	providers := stringSet(k.ProviderIDs)
	var keyIDs []string
	for _, e := range s.appAttestEvidence {
		if providers[e.Evidence.SessionID] {
			keyIDs = append(keyIDs, e.Evidence.KeyID)
		}
	}
	k.AppAttestKeyIDs = erasure.SortedUnique(keyIDs)
	ownAppKeys := stringSet(k.AppAttestKeyIDs)
	var sharedApp []string
	for _, e := range s.appAttestEvidence {
		if ownAppKeys[e.Evidence.KeyID] && !providers[e.Evidence.SessionID] && !s.erasedProviderLocked(e.Evidence.SessionID) {
			sharedApp = append(sharedApp, e.Evidence.KeyID)
		}
	}
	k.AppAttestKeyIDs, k.SharedAppAttestKeys = erasure.WithoutKeys(k.AppAttestKeyIDs, erasure.SortedUnique(sharedApp))
	stripeAccounts := []string{u.StripeAccountID}
	for _, id := range s.stripeWithdrawalsByAccount[account] {
		if w := s.stripeWithdrawalsByID[id]; w != nil {
			stripeAccounts = append(stripeAccounts, w.StripeAccountID)
		}
	}
	k.StripeAccountIDs = erasure.SortedUnique(stripeAccounts)
	if r := s.referrersByAccount[account]; r != nil {
		k.ReferrerCode = r.Code
	}
	var sessions []*store.BillingSession
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
	for _, item := range s.erasureOutbox {
		r := s.erasureRequests[item.RequestID]
		if r == nil || r.AccountID != account || r.State == store.ErasureErased {
			continue
		}
		switch item.Target {
		case store.ErasureTargetStripeAccount:
			k.StripeAccountIDs = append(k.StripeAccountIDs, item.ExternalID)
		case store.ErasureTargetGlobalRecipient:
			recipients = append(recipients, item.ExternalID)
		case store.ErasureTargetCheckoutSessions:
			k.CheckoutSessionIDs = append(k.CheckoutSessionIDs, strings.Split(item.ExternalID, ",")...)
		}
	}
	k.StripeAccountIDs = erasure.SortedUnique(k.StripeAccountIDs)
	k.CheckoutSessionIDs = erasure.SortedUnique(k.CheckoutSessionIDs)
	k.RecipientIDs = erasure.SortedUnique(recipients)
	if inv := s.machineInventory; inv != nil {
		digests := map[string]bool{}
		for _, serial := range k.Serials {
			digests[erasure.MDASerialDigest(serial)] = true
		}
		for alias, machine := range inv.Aliases {
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
	for sid, o := range s.machineInventory.Sessions {
		if o.AccountID != account && !s.erasedAccounts[o.AccountID] && s.machineInventory.SessionMachines[sid] == machine {
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
