package store

import (
	"testing"
	"time"
)

func TestProviderEarningsStoreContract(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			testProviderEarningsStoreContract(t, st)
		})
	}
}

func testProviderEarningsStoreContract(t *testing.T, st Store) {
	t.Helper()

	accountA := uniqueID("earnings-account-a")
	accountB := uniqueID("earnings-account-b")
	keyA := uniqueID("provider-key-a")
	keyB := uniqueID("provider-key-b")
	base := time.Date(2026, time.August, 22, 12, 0, 0, 0, time.UTC)
	records := []*ProviderEarning{
		{
			AccountID: accountA, ProviderID: "provider-a", ProviderKey: keyA,
			JobID: uniqueID("job-oldest"), Model: "model-a", AmountMicroUSD: 1_000,
			PromptTokens: 10, CompletionTokens: 50, CreatedAt: base,
		},
		{
			AccountID: accountA, ProviderID: "provider-b", ProviderKey: keyB,
			JobID: uniqueID("job-middle"), Model: "model-b", AmountMicroUSD: 2_000,
			PromptTokens: 20, CompletionTokens: 100, CreatedAt: base.Add(time.Minute),
		},
		{
			AccountID: accountA, ProviderID: "provider-a", ProviderKey: keyA,
			JobID: uniqueID("job-newest"), Model: "model-a", AmountMicroUSD: 1_500,
			PromptTokens: 15, CompletionTokens: 75, CreatedAt: base.Add(2 * time.Minute),
		},
		{
			AccountID: accountB, ProviderID: "provider-a-new-owner", ProviderKey: keyA,
			JobID: uniqueID("job-other-account"), Model: "model-a", AmountMicroUSD: 4_000,
			PromptTokens: 40, CompletionTokens: 200, CreatedAt: base.Add(3 * time.Minute),
		},
	}
	for _, earning := range records {
		if err := st.RecordProviderEarning(earning); err != nil {
			t.Fatalf("record earning %q: %v", earning.JobID, err)
		}
	}

	accountEarnings, err := st.GetAccountEarnings(accountA, 50)
	if err != nil {
		t.Fatalf("get account earnings: %v", err)
	}
	if len(accountEarnings) != 3 {
		t.Fatalf("account earnings = %d, want 3", len(accountEarnings))
	}
	wantAccountJobs := []string{records[2].JobID, records[1].JobID, records[0].JobID}
	for i, want := range wantAccountJobs {
		if accountEarnings[i].JobID != want {
			t.Fatalf("account earnings[%d].job_id = %q, want %q", i, accountEarnings[i].JobID, want)
		}
		if accountEarnings[i].ID == 0 {
			t.Fatalf("account earnings[%d] has no assigned ID", i)
		}
	}
	limited, err := st.GetAccountEarnings(accountA, 2)
	if err != nil || len(limited) != 2 ||
		limited[0].JobID != records[2].JobID ||
		limited[1].JobID != records[1].JobID {
		t.Fatalf("limited account earnings = %+v err=%v", limited, err)
	}
	otherAccount, err := st.GetAccountEarnings(accountB, 50)
	if err != nil || len(otherAccount) != 1 || otherAccount[0].JobID != records[3].JobID {
		t.Fatalf("other account earnings = %+v err=%v", otherAccount, err)
	}

	providerEarnings, err := st.GetProviderEarnings(keyA, 50)
	if err != nil {
		t.Fatalf("get provider earnings: %v", err)
	}
	wantProviderJobs := []string{records[3].JobID, records[2].JobID, records[0].JobID}
	if len(providerEarnings) != len(wantProviderJobs) {
		t.Fatalf("provider earnings = %d, want %d", len(providerEarnings), len(wantProviderJobs))
	}
	for i, want := range wantProviderJobs {
		if providerEarnings[i].JobID != want {
			t.Fatalf("provider earnings[%d].job_id = %q, want %q", i, providerEarnings[i].JobID, want)
		}
	}
	limited, err = st.GetProviderEarnings(keyA, 2)
	if err != nil || len(limited) != 2 ||
		limited[0].JobID != records[3].JobID ||
		limited[1].JobID != records[2].JobID {
		t.Fatalf("limited provider earnings = %+v err=%v", limited, err)
	}
	if missing, err := st.GetProviderEarnings(uniqueID("missing-key"), 50); err != nil || len(missing) != 0 {
		t.Fatalf("missing provider earnings = %+v err=%v", missing, err)
	}

	providerSummary, err := st.GetProviderEarningsSummary(keyA)
	if err != nil {
		t.Fatalf("get provider summary: %v", err)
	}
	if providerSummary.Count != 3 ||
		providerSummary.TotalMicroUSD != 6_500 ||
		providerSummary.PromptTokens != 65 ||
		providerSummary.CompletionTokens != 325 {
		t.Fatalf("provider summary mismatch: %+v", providerSummary)
	}
	accountSummary, err := st.GetAccountEarningsSummary(accountA)
	if err != nil {
		t.Fatalf("get account summary: %v", err)
	}
	if accountSummary.Count != 3 ||
		accountSummary.TotalMicroUSD != 4_500 ||
		accountSummary.PromptTokens != 45 ||
		accountSummary.CompletionTokens != 225 {
		t.Fatalf("account summary mismatch: %+v", accountSummary)
	}
}
