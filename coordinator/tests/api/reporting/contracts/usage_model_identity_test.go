package reporting_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestHandleUsageUsesRecordedPublicModelOnly(t *testing.T) {
	f := testkit.New(t, api.ServerConfig{})
	srv, st, reg := f.Server, f.Store, f.Registry
	const aliasFP8 = "mlx-community/gemma-4-26b-a4b-it-fp8"
	const aliasQAT = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
	reg.SetModelAliases(map[string]registry.AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT},
	})
	st.RecordUsage(store.UsageRecord{ProviderID: "p1", ConsumerKey: "acct-1", Model: aliasFP8, PublicModel: "gemma-4-26b", RequestID: "req-alias", PromptTokens: 10, CompletionTokens: 5, CostMicroUSD: 100})
	st.RecordUsage(store.UsageRecord{ProviderID: "p2", ConsumerKey: "acct-1", Model: aliasQAT, RequestID: "req-raw", PromptTokens: 3, CompletionTokens: 2, CostMicroUSD: 50})

	req := httptest.NewRequest(http.MethodGet, "/v1/payments/usage", nil)
	token := testkit.NewSessions(t, srv, st).Token("acct-1")
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body = %s", rec.Code, rec.Body.String())
	}
	var resp struct {
		Usage []struct {
			JobID string `json:"job_id"`
			Model string `json:"model"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode usage: %v", err)
	}
	got := map[string]string{}
	for _, u := range resp.Usage {
		got[u.JobID] = u.Model
	}
	if got["req-alias"] != "gemma-4-26b" {
		t.Fatalf("alias usage model = %q, want public alias", got["req-alias"])
	}
	if got["req-raw"] != aliasQAT {
		t.Fatalf("raw usage model = %q, want concrete build", got["req-raw"])
	}
}
