package memory

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// This file is the memory form of the rule table in
// coordinator/internal/store/erasure/rules.go: MemoryStore.PlanAccountErasure
// and MemoryStore.ScrubAccount run the same rules, in the same order, over the
// memory maps.

// memoryRule counts the items a rule links to the account and, when apply
// is set, changes them. The memory store holds no rows for the rules mapped
// to memoryNoTable.
type memoryRule func(s *MemoryStore, k *erasure.Keys, now time.Time, apply bool) int64

func memoryNoTable(*MemoryStore, *erasure.Keys, time.Time, bool) int64 { return 0 }

// memoryErasureRules maps every rule name in erasure.Rules to its memory
// form. runMemoryRulesLocked fails on a rule without one, and
// TestErasurePlanRunsEveryRuleInOrder checks the plan of each backend.
var memoryErasureRules = map[string]memoryRule{
	"legacy_mdm_cohort": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		var n int64
		for _, member := range s.legacyMDMCohort {
			if member.AccountID == k.AccountID {
				n++
			}
		}
		if apply {
			kept := s.legacyMDMCohort[:0]
			for _, member := range s.legacyMDMCohort {
				if member.AccountID != k.AccountID {
					kept = append(kept, member)
				}
			}
			s.legacyMDMCohort = kept
		}
		return n
	},
	"small_models_interest": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		if _, ok := s.smallModelsInterest[k.AccountID]; !ok {
			return 0
		}
		if apply {
			delete(s.smallModelsInterest, k.AccountID)
		}
		return 1
	},
	"users": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"api_keys": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"provider_tokens": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"device_codes": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		var n int64
		for code, dc := range s.history.DeviceCodesByCode {
			if dc.AccountID == k.AccountID {
				n++
				if apply {
					delete(s.history.DeviceCodesByCode, code)
					delete(s.history.DeviceCodesByUserCode, dc.UserCode)
				}
			}
		}
		return n
	},
	"providers": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"provider_sessions": func(s *MemoryStore, k *erasure.Keys, now time.Time, apply bool) int64 {
		var n int64
		for i := range s.history.ProviderSessions {
			ps := &s.history.ProviderSessions[i]
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
			for sid, o := range s.machineInventory.Sessions {
				if o.AccountID == k.AccountID {
					o.VerifiedSerial = ""
					s.machineInventory.Sessions[sid] = o
				}
			}
		}
		return n
	},
	"provider_log_reports": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		var n int64
		kept := s.history.LogReports[:0:0]
		for _, r := range s.history.LogReports {
			if r.AccountID == k.AccountID {
				n++
				continue
			}
			kept = append(kept, r)
		}
		if apply {
			s.history.LogReports = kept
		}
		return n
	},
	"provider_trust_reuse": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"provider_verification_jobs": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"code_attestations": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"code_attest_push_budgets": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"machine_aliases_account": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		if s.machineInventory == nil {
			return 0
		}
		var n int64
		for alias := range s.machineInventory.Aliases {
			if (alias.Kind == "app_attest" || alias.Kind == "legacy_se") && alias.Scope == k.AccountID {
				n++
				if apply {
					delete(s.machineInventory.Aliases, alias)
				}
			}
		}
		return n
	},
	"machine_aliases_mda_serial": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		if s.machineInventory == nil {
			return 0
		}
		var n int64
		for _, digest := range k.MDADigestsToDelete {
			alias := store.MachineAlias{Kind: "mda_serial", Digest: digest}
			if _, ok := s.machineInventory.Aliases[alias]; ok {
				n++
				if apply {
					delete(s.machineInventory.Aliases, alias)
				}
			}
		}
		return n
	},
	"app_attest_evidence_blobs": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"app_attest_evidence": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"usage_request_location": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		var n int64
		for i := range s.history.Usage {
			// The memory store keeps the raw consumer key; Postgres keeps its hash.
			if s.history.Usage[i].ConsumerKey == k.AccountID && s.history.Usage[i].RequestLocation != nil {
				n++
				if apply {
					s.history.Usage[i].RequestLocation = nil
				}
			}
		}
		return n
	},
	"inference_routes_consumer_region": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"inference_routes_provider_region": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"referrers": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"billing_sessions_referral_code": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"billing_sessions": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"ledger_entries_stripe_reference": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		var n int64
		for i := range s.history.LedgerEntries {
			e := &s.history.LedgerEntries[i]
			if e.AccountID == k.AccountID && strings.HasPrefix(e.Reference, "stripe:") {
				n++
				if apply {
					e.Reference = "stripe:erased"
				}
			}
		}
		return n
	},
	"ledger_entries_admin_note": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		var n int64
		for i := range s.history.LedgerEntries {
			e := &s.history.LedgerEntries[i]
			if e.AccountID == k.AccountID && (e.Type == store.LedgerAdminCredit || e.Type == store.LedgerAdminReward) && e.Reference != string(e.Type) {
				n++
				if apply {
					e.Reference = string(e.Type)
				}
			}
		}
		return n
	},
	"global_payout_recipients": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
		if _, ok := s.globalRecipients[k.AccountID]; !ok {
			return 0
		}
		if apply {
			s.globalRecipients[k.AccountID] = store.GlobalRecipient{ID: uuid.NewString(), AccountID: k.AccountID}
		}
		return 1
	},
	"global_payout_withdrawals": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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
	"stripe_withdrawals": func(s *MemoryStore, k *erasure.Keys, _ time.Time, apply bool) int64 {
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

func (s *MemoryStore) runMemoryRulesLocked(k *erasure.Keys, now time.Time, apply bool) ([]store.ErasureRowCount, error) {
	out := make([]store.ErasureRowCount, 0, len(erasure.Rules))
	for _, rule := range erasure.Rules {
		fn, ok := memoryErasureRules[rule.Name]
		if !ok {
			return nil, fmt.Errorf("store: no memory erasure rule %q", rule.Name)
		}
		out = append(out, rule.RowCount(fn(s, k, now, apply)))
	}
	return out, nil
}
