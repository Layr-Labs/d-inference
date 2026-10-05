package billing_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func getAccountEarningsMap(t *testing.T, account string, rows []store.ProviderEarning) map[string]any {
	t.Helper()
	srv, st := stripeSessionServer(t)
	for i := range rows {
		if err := st.CreditProviderAccount(&rows[i]); err != nil {
			t.Fatalf("credit %d: %v", i, err)
		}
	}
	req := httptest.NewRequest(http.MethodGet, "/v1/provider/account-earnings", nil)
	req.Header.Set("Authorization", "Bearer "+testkit.NewSessions(t, srv, st).Token(account))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d: %s", w.Code, w.Body.String())
	}
	var m map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func earningsNum(t *testing.T, m map[string]any, key string) float64 {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("response missing key %q: %v", key, m)
	}
	f, ok := v.(float64)
	if !ok {
		t.Fatalf("key %q = %v (%T), want number", key, v, v)
	}
	return f
}

func earningsStr(t *testing.T, m map[string]any, key string) string {
	t.Helper()
	v, ok := m[key]
	if !ok {
		t.Fatalf("response missing key %q: %v", key, m)
	}
	s, ok := v.(string)
	if !ok {
		t.Fatalf("key %q = %v (%T), want string", key, v, v)
	}
	return s
}

// W6: account-earnings reports the work/base-reward split.
func TestW6AccountEarningsWorkBaseRewardSplit(t *testing.T) {
	account := "acct-w6"
	m := getAccountEarningsMap(t, account, []store.ProviderEarning{
		{AccountID: account, ProviderID: "n1", ProviderKey: "k1", JobID: "w-job-1", Model: "qwen", AmountMicroUSD: 300_000},
		{AccountID: account, ProviderID: "n1", ProviderKey: "k1", JobID: "w-job-2", Model: "qwen", AmountMicroUSD: 200_000},
		{AccountID: account, ProviderID: "", ProviderKey: "k1", JobID: "floor:2026-01:k1", Model: "base_reward", AmountMicroUSD: 1_250_000},
	})
	// Existing fields unchanged.
	if got := earningsNum(t, m, "total_micro_usd"); got != 1_750_000 {
		t.Fatalf("total_micro_usd = %v, want 1750000", got)
	}
	if got := earningsStr(t, m, "total_usd"); got != "1.750000" {
		t.Fatalf("total_usd = %q", got)
	}
	if got := earningsNum(t, m, "count"); got != 2 {
		t.Fatalf("count = %v, want 2", got)
	}
	// New fields.
	if got := earningsNum(t, m, "base_reward_micro_usd"); got != 1_250_000 {
		t.Fatalf("base_reward_micro_usd = %v, want 1250000", got)
	}
	if got := earningsStr(t, m, "base_reward_usd"); got != "1.250000" {
		t.Fatalf("base_reward_usd = %q, want 1.250000", got)
	}
	if got := earningsNum(t, m, "work_micro_usd"); got != 500_000 {
		t.Fatalf("work_micro_usd = %v, want 500000", got)
	}
	if got := earningsStr(t, m, "work_usd"); got != "0.500000" {
		t.Fatalf("work_usd = %q, want 0.500000", got)
	}
}

// work_micro_usd is floored at zero even if the base-reward total exceeds the
// summary total (e.g. a backfill that counted a draw the total never saw).
func TestAccountEarningsWorkFlooredAtZero(t *testing.T) {
	account := "acct-work-floor"
	m := getAccountEarningsMap(t, account, []store.ProviderEarning{
		{AccountID: account, ProviderKey: "k1", JobID: "floor:2026-01:k1", Model: "base_reward", AmountMicroUSD: 1_000},
		{AccountID: account, ProviderID: "n1", ProviderKey: "k1", JobID: "neg-job", Model: "qwen", AmountMicroUSD: -5_000},
	})
	if got := earningsNum(t, m, "total_micro_usd"); got >= 1_000 {
		t.Fatalf("setup: total_micro_usd = %v, want below the base reward", got)
	}
	if got := earningsNum(t, m, "work_micro_usd"); got != 0 {
		t.Fatalf("work_micro_usd = %v, want 0", got)
	}
	if got := earningsStr(t, m, "work_usd"); got != "0.000000" {
		t.Fatalf("work_usd = %q, want 0.000000", got)
	}
}
