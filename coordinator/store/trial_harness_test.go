package store

import (
	"context"
	"errors"
	"testing"
)

func trialBackends(t *testing.T, run func(*testing.T, Store, TrialStore)) {
	t.Helper()
	for _, name := range []string{"memory", "postgres"} {
		t.Run(name, func(t *testing.T) {
			var s Store
			if name == "postgres" {
				s = testPostgresStore(t)
			} else {
				s = NewMemory(Config{})
			}
			trial, ok := As[TrialStore](NewCached(s, CacheConfig{}))
			if !ok {
				t.Fatal("cached store hides trial capability")
			}
			run(t, s, trial)
		})
	}
}
func trialRequest(id, account string, hold int64) TrialReservation {
	return TrialReservation{ID: id, AccountID: account, CampaignID: "bonsai-2-lifetime", Model: "bonsai-build", LimitTokens: 1000, ReservedTokens: hold, PricingJSON: []byte(`{"input":10,"output":20}`)}
}
func trialSettlement(r TrialReservation, prompt, completion int) TrialSettlement {
	return TrialSettlement{Usage: UsageRecord{ConsumerKey: r.AccountID, RequestID: r.ID, Model: r.Model, ProviderID: "provider", PromptTokens: prompt, CompletionTokens: completion}, SubsidyMicroUSD: 100, Earning: &ProviderEarning{AccountID: "provider-account", ProviderID: "provider", ProviderKey: "provider-key", JobID: r.ID, Model: r.Model, PromptTokens: prompt, CompletionTokens: completion, AmountMicroUSD: 80}}
}
func requireTrialError(t *testing.T, got, want error) {
	t.Helper()
	if !errors.Is(got, want) {
		t.Fatalf("error = %v; want %v", got, want)
	}
}
func reserveAndDispatch(t *testing.T, s TrialStore, r TrialReservation) {
	t.Helper()
	if _, err := s.ReserveTrial(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	if err := s.MarkTrialDispatched(context.Background(), r.ID); err != nil {
		t.Fatal(err)
	}
}
func assertAllowance(t *testing.T, s TrialStore, r TrialReservation, used, held int64) {
	t.Helper()
	a, err := s.GetTrialAllowance(context.Background(), r.AccountID, r.CampaignID)
	if err != nil {
		t.Fatal(err)
	}
	if a.UsedTokens != used || a.ReservedTokens != held {
		t.Fatalf("allowance=%+v; want used=%d held=%d", a, used, held)
	}
}
