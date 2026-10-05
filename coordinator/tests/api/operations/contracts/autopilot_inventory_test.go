package operations_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

type unavailableInventoryLedger struct {
	*memory.MemoryStore
}

func (unavailableInventoryLedger) AutopilotRecords(context.Context, time.Time, int) ([]store.AutopilotRecord, error) {
	return nil, errors.New("ledger unavailable")
}

func TestAutopilotInventoryIndependentOfLedger(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	r := registry.New(logger)
	st := unavailableInventoryLedger{memory.NewMemory(store.Config{})}
	srv := testkit.NewServer(t, r, st, api.ServerConfig{}, logger)
	srv.SetAdminKey("inventory-admin-key")
	if w := doReq(srv, http.MethodGet, "/v1/admin/autopilot", "Bearer inventory-admin-key", ""); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("ledger fault not exercised: %d %s", w.Code, w.Body.String())
	}
	if w := doReq(srv, http.MethodGet, "/v1/admin/autopilot/inventory", "Bearer inventory-admin-key", ""); w.Code != http.StatusOK {
		t.Fatalf("inventory depends on ledger: %d %s", w.Code, w.Body.String())
	}
}

func TestAutopilotInventoryAdminHTTP(t *testing.T) {
	f := testkit.New(t, api.ServerConfig{})
	f.Server.SetAdminKey("inventory-admin-key")
	sessions := testkit.NewSessions(t, f.Server, f.Store)
	userToken := sessions.Token("ordinary-account")
	server := httptest.NewServer(f.Server.Handler())
	t.Cleanup(server.Close)
	get := func(auth string, status int) []byte {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, server.URL+"/v1/admin/autopilot/inventory", nil)
		if auth != "" {
			req.Header.Set("Authorization", "Bearer "+auth)
		}
		res, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, err := io.ReadAll(res.Body)
		if err != nil {
			t.Fatal(err)
		}
		if res.StatusCode != status {
			t.Fatalf("status=%d want=%d body=%s", res.StatusCode, status, body)
		}
		if status == http.StatusOK && res.Header.Get("Cache-Control") != "no-store" {
			t.Fatal("inventory response must not be cached")
		}
		return body
	}
	get("", http.StatusUnauthorized)
	get("invalid-key", http.StatusUnauthorized)
	get(userToken, http.StatusForbidden)
	var empty registry.AutopilotInventoryReport
	if err := json.Unmarshal(get("inventory-admin-key", http.StatusOK), &empty); err != nil {
		t.Fatal(err)
	}
	if empty.EnrolledProviders != 0 || empty.Models == nil || empty.ModelsPerProvider == nil {
		t.Fatalf("empty inventory: %+v", empty)
	}
	// The controller is not configured and this is only a reported saved
	// selection, not an advertised or routable model.
	f.Registry.Register("secret-connection", nil, &protocol.RegisterMessage{
		ModelAutopilot: &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true, Revision: "secret-revision", SessionID: "secret-session", SelectedModels: []string{"saved-model", "saved-model"}},
	})
	body := get("inventory-admin-key", http.StatusOK)
	for _, secret := range []string{"secret-connection", "secret-revision", "secret-session", "ordinary-account", "inventory-admin-key"} {
		if strings.Contains(string(body), secret) {
			t.Fatalf("response leaks %q", secret)
		}
	}
	var report registry.AutopilotInventoryReport
	if err := json.Unmarshal(body, &report); err != nil {
		t.Fatal(err)
	}
	if report.EnrolledProviders != 1 || report.TotalApprovals != 1 || len(report.Models) != 1 || report.Models[0].ModelID != "saved-model" || report.Models[0].ApprovedProviders != 1 {
		t.Fatalf("inventory=%+v", report)
	}
}
