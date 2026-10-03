package store

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

// findMemoryMarker walks every value reachable from the MemoryStore (maps,
// slices, pointers, unexported fields) and returns the paths of strings and
// byte slices that contain marker.
func findMemoryMarker(s *MemoryStore, marker string) []string {
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

// memoryMarkerAllowList matches erasureMarkerAllowList for the memory store.
var memoryMarkerAllowList = []string{"MemoryStore.erasureOutbox["}

func seedMemoryMarkers(t *testing.T, s *MemoryStore, account, marker string) {
	t.Helper()
	ctx := context.Background()
	now := time.Now()
	m := func(suffix string) string { return marker + "-" + account + "-" + suffix }
	if err := s.CreateUser(&User{AccountID: account, PrivyUserID: "did:privy:" + m("privy"), Email: m("email")}); err != nil {
		t.Fatal(err)
	}
	if err := s.SetUserStripeAccount(account, "acct_"+m("stripe"), m("status"), m("country"), m("dest"), m("last4"), true); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.CreateAPIKey(account, APIKeyCreate{Name: m("key")}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateProviderToken(&ProviderToken{TokenHash: hashKey(m("token")), AccountID: account, Label: m("hostname"), Active: true}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateDeviceCode(&DeviceCode{DeviceCode: "dc-" + account, UserCode: m("uc"), Status: "pending", ExpiresAt: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if err := s.ApproveDeviceCode("dc-"+account, account); err != nil {
		t.Fatal(err)
	}
	provider, seKey, serial := "prov-"+account, "se-"+account, m("serial")
	if err := s.UpsertProvider(ctx, ProviderRecord{
		ID: provider, Hardware: []byte(`{}`), Models: []byte(`[]`), Backend: "mlx", AccountID: account,
		SerialNumber: serial, SEPublicKey: seKey, Location: &ProviderLocation{City: m("city")},
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
	if _, err := s.UpsertProviderTrustReuse(ctx, ProviderTrustReuse{SEPubKey: seKey, Serial: serial, MDAUDID: m("udid"), TrustLevel: "hardware", HardwareProofVerifiedAt: now}, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpsertVerificationJob(ctx, VerificationJob{SEPubKey: seKey, Serial: serial, UDID: m("udid"), Kind: VerificationTaskSecurityInfo, State: VerificationStatePending}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertCodeAttestation(ctx, CodeAttestation{SEPubKey: seKey, APNsToken: m("apns"), AttestedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertCodeAttestPushBudget(ctx, CodeAttestPushBudget{SEPubKey: seKey, TokenHash: m("tokhash"), NextPushAt: now}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ObserveMachine(ctx, MachineObservation{SessionID: provider, AccountID: account, At: now, SEKey: seKey, VerifiedSerial: serial}); err != nil {
		t.Fatal(err)
	}
	if err := s.BeginAppAttestEvidence(ctx, AppAttestEvidence{ID: "ev-" + account, SessionID: provider, KeyID: "kid-" + account, ReceivedAt: now, Action: "attestation",
		ProofField: m("proof-field"), Proof: []byte(m("proof")), SHA256: "abc", Context: json.RawMessage(`{"boot":"` + m("boot") + `"}`)}); err != nil {
		t.Fatal(err)
	}
	s.RecordUsage(UsageRecord{ProviderID: "prov-x", ConsumerKey: account, Model: "m", RequestLocation: &ProviderLocation{City: m("usage-city")}})
	if err := s.RecordInferenceRoute(&InferenceRouteRecord{RequestID: "r1-" + account, Model: "m", ConsumerKeyHash: hashKey(account), ConsumerRegion: m("region")}); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordInferenceRoute(&InferenceRouteRecord{RequestID: "r2-" + account, Model: "m", ProviderID: provider, ProviderRegion: m("pregion")}); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateReferrer(account, m("code")); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateBillingSession(&BillingSession{ID: "bs-" + account, AccountID: account, PaymentMethod: "stripe", AmountMicroUSD: 1, ExternalID: "cs_" + m("checkout"), Status: "completed", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := s.Credit(account, 5, LedgerStripeDeposit, "stripe:cs_"+m("checkout")); err != nil {
		t.Fatal(err)
	}
	if err := s.CreditWithdrawable(account, 5, LedgerAdminReward, "admin_reward:"+m("note")); err != nil {
		t.Fatal(err)
	}
	if _, err := s.PrepareGlobalRecipient(GlobalRecipient{ID: "g-" + account, AccountID: account, Country: m("gcountry"), RecipientID: "acct_" + m("recipient"), PayoutMethodID: m("pm"), Last4: m("glast4")}); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	if s.globalPayouts == nil {
		s.globalPayouts = map[string]GlobalPayout{}
	}
	s.globalPayouts["gp-"+account] = GlobalPayout{ID: "gp-" + account, AccountID: account, RecipientID: "acct_" + m("recipient"), PayoutMethodID: m("pm"), Request: json.RawMessage(`{"to":"` + m("req") + `"}`), Status: "failed"}
	s.mu.Unlock()
	wd := &StripeWithdrawal{ID: "wd-" + account, AccountID: account, StripeAccountID: "acct_" + m("stripe"), AmountMicroUSD: 1, NetMicroUSD: 1, Method: "standard", Status: "pending"}
	if err := s.CreateStripeWithdrawalWithDebit(wd, LedgerStripePayout, "stripe_withdraw:"+wd.ID); err != nil {
		t.Fatal(err)
	}
	wd.Status = "paid"
	if err := s.UpdateStripeWithdrawal(wd); err != nil {
		t.Fatal(err)
	}
}

func TestErasureMarkerMemory(t *testing.T) {
	ctx := context.Background()
	s := NewMemory(Config{})
	seedMemoryMarkers(t, s, "acct-A", piiMarker)
	seedMemoryMarkers(t, s, "acct-B", keepMarker)
	if err := s.RecordReferral(piiMarker+"-acct-A-code", "acct-B"); err != nil {
		t.Fatal(err)
	}
	if err := s.CreateBillingSession(&BillingSession{ID: "bs-B-ref", AccountID: "acct-B", PaymentMethod: "stripe", AmountMicroUSD: 1, Status: "completed", ReferralCode: piiMarker + "-acct-A-code"}); err != nil {
		t.Fatal(err)
	}
	keepBefore := len(findMemoryMarker(s, keepMarker))

	plan, err := s.PlanAccountErasure(ctx, "acct-A", nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range plan.Rows {
		if fn := memoryErasureRules[r.Rule]; r.Rows == 0 && reflect.ValueOf(fn).Pointer() != reflect.ValueOf(memoryNoTable).Pointer() {
			t.Errorf("rule %s has no memory fixture", r.Rule)
		}
	}
	now := time.Now().UTC()
	if _, err := s.SaveErasurePlan(ctx, "acct-A", "admin_key", plan.ErasureCounts, "token", now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	req, err := s.RequestAccountErasure(ctx, ErasureConfirm{AccountID: "acct-A", ConfirmToken: "token", Email: plan.Email, Now: now})
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
