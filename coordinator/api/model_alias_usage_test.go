package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestHandleUsageUsesRecordedPublicModelOnly(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	reg.SetModelAliases(map[string]registry.AliasTarget{
		"gemma-4-26b": {Desired: aliasQAT},
	})
	st.RecordUsageFullWithPublicModel("p1", "acct-1", "", aliasFP8, "gemma-4-26b", "req-alias", 10, 5, 100, nil)
	st.RecordUsageFull("p2", "acct-1", "", aliasQAT, "req-raw", 3, 2, 50, nil)

	req := httptest.NewRequest(http.MethodGet, "/v1/payments/usage", nil)
	req = req.WithContext(context.WithValue(req.Context(), ctxKeyConsumer, "acct-1"))
	rec := httptest.NewRecorder()
	srv.handleUsage(rec, req)

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
