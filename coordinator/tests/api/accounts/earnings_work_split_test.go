package accounts_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// W7: /v1/me/summary reports lifetime_base_reward_micro_usd, others unchanged.
func TestW7MySummaryLifetimeBaseReward(t *testing.T) {
	srv, st := newMeTestServer(t)
	const account = "acct-w7"
	rows := []store.ProviderEarning{
		{AccountID: account, ProviderID: "n1", ProviderKey: "k1", JobID: "w-job-1", Model: "qwen", AmountMicroUSD: 300_000},
		{AccountID: account, ProviderID: "n1", ProviderKey: "k1", JobID: "w-job-2", Model: "qwen", AmountMicroUSD: 200_000},
		{AccountID: account, ProviderID: "", ProviderKey: "k1", JobID: "floor:2026-01:k1", Model: "base_reward", AmountMicroUSD: 1_250_000},
	}
	for i := range rows {
		if err := st.CreditProviderAccount(&rows[i]); err != nil {
			t.Fatalf("credit %d: %v", i, err)
		}
	}

	w := httptest.NewRecorder()
	srv.HandleMySummary(w, reqWithUser(http.MethodGet, "/v1/me/summary", "", account))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	var m map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &m); err != nil {
		t.Fatal(err)
	}
	num := func(key string) float64 {
		t.Helper()
		f, ok := m[key].(float64)
		if !ok {
			t.Fatalf("key %q = %v (%T), want number", key, m[key], m[key])
		}
		return f
	}
	if got := num("lifetime_micro_usd"); got != 1_750_000 {
		t.Fatalf("lifetime_micro_usd = %v, want 1750000", got)
	}
	if got := num("lifetime_jobs"); got != 2 {
		t.Fatalf("lifetime_jobs = %v, want 2", got)
	}
	if got := num("lifetime_base_reward_micro_usd"); got != 1_250_000 {
		t.Fatalf("lifetime_base_reward_micro_usd = %v, want 1250000", got)
	}
}
