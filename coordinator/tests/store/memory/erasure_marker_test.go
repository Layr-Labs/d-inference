package memory_test

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/erasure"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// The memory marker test seeds two accounts with marker strings in every
// value the rule table covers, erases acct-A, and walks every value the
// MemoryStore holds for the marker. acct-B carries keepMarker and must keep
// all of it.

const (
	piiMarker  = "PIIMARK"
	keepMarker = "KEEPMARK"
)

// memoryRulesWithoutTable are the rules whose tables the memory store does
// not keep: App Attest receipts, payments and provider payouts.
var memoryRulesWithoutTable = map[string]bool{
	"app_attest_receipt_jobs": true, "app_attest_receipt_blobs": true, "app_attest_receipts": true,
	"payments_consumer_address": true, "payments_provider_address": true, "provider_payouts_address": true,
}

// findMemoryMarker walks every value reachable from the MemoryStore (maps,
// slices, pointers, unexported fields) and returns the paths of strings and
// byte slices that contain marker.
func findMemoryMarker(s *memory.MemoryStore, marker string) []string {
	var hits []string
	seen := map[uintptr]bool{}
	var walk func(v reflect.Value, path string)
	walk = func(v reflect.Value, path string) {
		switch v.Kind() {
		case reflect.String:
			if strings.Contains(v.String(), marker) {
				hits = append(hits, path)
			}
		case reflect.Slice:
			if v.Type().Elem().Kind() == reflect.Uint8 {
				if strings.Contains(string(v.Bytes()), marker) {
					hits = append(hits, path)
				}
				return
			}
			for i := 0; i < v.Len(); i++ {
				walk(v.Index(i), fmt.Sprintf("%s[%d]", path, i))
			}
		case reflect.Array:
			for i := 0; i < v.Len(); i++ {
				walk(v.Index(i), fmt.Sprintf("%s[%d]", path, i))
			}
		case reflect.Map:
			iter := v.MapRange()
			for iter.Next() {
				walk(iter.Key(), path+"{key}")
				walk(iter.Value(), path+"{value}")
			}
		case reflect.Pointer:
			if v.IsNil() || seen[v.Pointer()] {
				return
			}
			seen[v.Pointer()] = true
			walk(v.Elem(), path)
		case reflect.Interface:
			if !v.IsNil() {
				walk(v.Elem(), path)
			}
		case reflect.Struct:
			for i := 0; i < v.NumField(); i++ {
				walk(v.Field(i), path+"."+v.Type().Field(i).Name)
			}
		}
	}
	walk(reflect.ValueOf(s), "MemoryStore")
	return hits
}

// memoryMarkerAllowList matches erasureMarkerAllowList of the PostgreSQL
// marker test: the outbox keeps each Stripe ID until Stripe confirms the
// deletion.
var memoryMarkerAllowList = []string{"MemoryStore.erasureOutbox["}

func seedMemoryMarkers(t *testing.T, s *memory.MemoryStore, account, marker string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now()
	m := func(suffix string) string { return marker + "-" + account + "-" + suffix }
	if err := s.CreateUser(&store.User{AccountID: account, PrivyUserID: "did:privy:" + m("privy"), Email: m("email")}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertSmallModelsInterest(ctx, store.SmallModelsInterest{AccountID: account, MacType: m("hardware"), Chip: m("chip"), RAMGB: 16}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(account, "acct_"+m("stripe"), m("status"), m("country"), m("dest"), m("last4"), true); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.CreateAPIKey(account, store.APIKeyCreate{Name: m("key")}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateProviderToken(&store.ProviderToken{TokenHash: store.HashKey(m("token")), AccountID: account, Label: m("hostname"), Active: true}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateDeviceCode(&store.DeviceCode{DeviceCode: "dc-" + account, UserCode: m("uc"), Status: "pending", ExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := s.ApproveDeviceCode("dc-"+account, account); err != nil {
		t.Fatal(err)
	}
	provider, seKey, serial := "prov-"+account, "se-"+account, m("serial")
	if err := s.UpsertProvider(ctx, store.ProviderRecord{
		ID: provider, Hardware: []byte(`{}`), Models: []byte(`[]`), Backend: "mlx", AccountID: account,
		SerialNumber: serial, SEPublicKey: seKey, Location: &store.ProviderLocation{City: m("city")},
		AttestationResult: json.RawMessage(`{"serial":"` + serial + `"}`), MDACertChain: json.RawMessage(`["` + m("cert") + `"]`),
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.OpenProviderSession(ctx, provider, serial, account); err != nil {
		t.Fatal(err)
	}
	if _, err := s.StoreLogReport(account, []byte(m("log"))); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpsertProviderTrustReuse(ctx, store.ProviderTrustReuse{SEPubKey: seKey, Serial: serial, MDAUDID: m("udid"), TrustLevel: "hardware", SIPEnabled: true, SecureBootFull: true, HardwareProofVerifiedAt: now}, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpsertVerificationJob(ctx, store.VerificationJob{SEPubKey: seKey, Serial: serial, UDID: m("udid"), Kind: store.VerificationTaskSecurityInfo, State: store.VerificationStatePending}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertCodeAttestation(ctx, store.CodeAttestation{SEPubKey: seKey, APNsToken: m("apns"), AttestedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertCodeAttestPushBudget(ctx, store.CodeAttestPushBudget{SEPubKey: seKey, TokenHash: m("tokhash"), NextPushAt: now}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ObserveMachine(ctx, store.MachineObservation{SessionID: provider, AccountID: account, At: now, SEKey: seKey, VerifiedSerial: serial}); err != nil {
		t.Fatal(err)
	}
	if err := s.BeginAppAttestEvidence(ctx, store.AppAttestEvidence{ID: "ev-" + account, SessionID: provider, KeyID: "kid-" + account, ReceivedAt: now, Action: "attestation",
		ProofField: m("proof-field"), Proof: []byte(m("proof")), SHA256: "abc", Context: json.RawMessage(`{"boot":"` + m("boot") + `"}`)}); err != nil {
		t.Fatal(err)
	}
	s.RecordUsage(store.UsageRecord{ProviderID: "prov-x", ConsumerKey: account, Model: "m", RequestLocation: &store.ProviderLocation{City: m("usage-city")}})
	if err := s.RecordInferenceRoute(&store.InferenceRouteRecord{RequestID: "r1-" + account, Model: "m", ConsumerKeyHash: store.HashKey(account), ConsumerRegion: m("region")}); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordInferenceRoute(&store.InferenceRouteRecord{RequestID: "r2-" + account, Model: "m", ProviderID: provider, ProviderRegion: m("pregion")}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateReferrer(account, m("code")); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateBillingSession(&store.BillingSession{ID: "bs-" + account, AccountID: account, PaymentMethod: "stripe", AmountMicroUSD: 1, ExternalID: "cs_" + m("checkout"), Status: "completed", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := s.Credit(account, 5, store.LedgerStripeDeposit, "stripe:cs_"+m("checkout")); err != nil {
		t.Fatal(err)
	}
	if err := s.CreditWithdrawable(account, 5, store.LedgerAdminReward, "admin_reward:"+m("note")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.PrepareGlobalRecipient(store.GlobalRecipient{ID: "g-" + account, AccountID: account, Country: m("gcountry"), RecipientID: "acct_" + m("recipient"), PayoutMethodID: m("pm"), Last4: m("glast4")}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateGlobalPayoutQuote(store.GlobalPayout{ID: "gp-" + account, AccountID: account, RecipientID: "acct_" + m("recipient"), RecipientGeneration: "gen-" + account,
		PayoutMethodID: m("pm"), AmountMicroUSD: 10_000, Request: json.RawMessage(`{"to":"` + m("req") + `"}`), ExpiresAt: now.Add(time.Hour), Status: "quoted"}); err != nil {
		t.Fatal(err)
	}
	wd := &store.StripeWithdrawal{ID: "wd-" + account, AccountID: account, StripeAccountID: "acct_" + m("stripe"), AmountMicroUSD: 1, NetMicroUSD: 1, Method: "standard", Status: "pending"}
	if err := s.CreateStripeWithdrawalWithDebit(wd, store.LedgerStripePayout, "stripe_withdraw:"+wd.ID); err != nil {
		t.Fatal(err)
	}
	wd.Status = "paid"
	if err := s.UpdateStripeWithdrawal(wd); err != nil {
		t.Fatal(err)
	}
}

func TestErasureMarkerMemory(t *testing.T) {
	ctx := context.Background()
	s := memory.NewMemory(store.Config{})
	seedMemoryMarkers(t, s, "acct-A", piiMarker)
	seedMemoryMarkers(t, s, "acct-B", keepMarker)
	if err := s.RecordReferral(piiMarker+"-acct-A-code", "acct-B"); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateBillingSession(&store.BillingSession{ID: "bs-B-ref", AccountID: "acct-B", PaymentMethod: "stripe", AmountMicroUSD: 1, Status: "completed", ReferralCode: piiMarker + "-acct-A-code"}); err != nil {
		t.Fatal(err)
	}
	// A Mac moved between accounts: both have a provider with se-shared,
	// whose trust row belongs to acct-B too and must stay.
	for _, p := range []store.ProviderRecord{
		{ID: "prov-A-shared", AccountID: "acct-A", SEPublicKey: "se-shared", Hardware: []byte(`{}`), Models: []byte(`[]`)},
		{ID: "prov-B-shared", AccountID: "acct-B", SEPublicKey: "se-shared", Hardware: []byte(`{}`), Models: []byte(`[]`)},
	} {
		if err := s.UpsertProvider(context.Background(), p); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.UpsertProviderTrustReuse(context.Background(), store.ProviderTrustReuse{SEPubKey: "se-shared", Serial: keepMarker + "-shared", TrustLevel: "hardware", HardwareProofVerifiedAt: time.Now()}, 0); err != nil {
		t.Fatal(err)
	}
	cohort, err := s.FreezeLegacyMDMCohort(ctx)
	if err != nil || len(cohort) != 2 {
		t.Fatalf("marker cohort = %+v, %v; want both accounts", cohort, err)
	}
	keepBefore := len(findMemoryMarker(s, keepMarker))

	plan, err := s.PlanAccountErasure(ctx, "acct-A", nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range plan.Rows {
		if r.Rows == 0 && !memoryRulesWithoutTable[r.Rule] {
			t.Errorf("rule %s has no memory fixture", r.Rule)
		}
	}
	// The scrub runs after the bounce window of the paid withdrawal.
	now := time.Now().UTC().Add(erasure.StripePayoutBounceWindow + time.Hour)
	if _, err := s.SaveErasurePlan(ctx, "acct-A", "admin_key", plan.ErasureCounts, nil, "token", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	req, err := s.RequestAccountErasure(ctx, store.ErasureConfirm{AccountID: "acct-A", ConfirmToken: "token", Email: plan.Email, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ScrubAccount(ctx, req.ID, now); err != nil {
		t.Fatal(err)
	}
	for _, hit := range findMemoryMarker(s, piiMarker) {
		allowed := false
		for _, prefix := range memoryMarkerAllowList {
			allowed = allowed || strings.HasPrefix(hit, prefix)
		}
		if !allowed {
			t.Errorf("personal data left at %s", hit)
		}
	}
	if keepAfter := len(findMemoryMarker(s, keepMarker)); keepAfter != keepBefore {
		t.Errorf("the other account's data changed: %d marker values before, %d after", keepBefore, keepAfter)
	}
	if code, err := s.GetReferrerForAccount("acct-B"); err != nil || strings.Contains(code, piiMarker) || code == "" {
		t.Errorf("referral of acct-B = %q, %v", code, err)
	}
}
