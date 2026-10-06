package api_test

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestRuntimeSharesTransportObservationOwner(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	st := memory.NewMemory(store.Config{})
	runtime := api.NewRuntime(api.RuntimeDependencies{
		Registry: registry.New(logger), Store: st, Ledger: payments.NewLedger(st),
		ReadCache: readcache.New(), Logger: logger,
	}, api.ServerConfig{})
	t.Cleanup(runtime.Server.Close)
	if runtime.Server.Metrics() != runtime.Observation.Metrics() {
		t.Fatal("application and transport received different observation owners")
	}
	response := httptest.NewRecorder()
	runtime.Server.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/health", nil))
	if response.Code != http.StatusOK {
		t.Fatalf("composed health route = %d: %s", response.Code, response.Body.String())
	}
}

func TestRuntimeSharesTransportLedger(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	st := memory.NewMemory(store.Config{})
	key, _, err := st.CreateAPIKey("runtime-account", store.APIKeyCreate{})
	if err != nil {
		t.Fatal(err)
	}
	ledger := payments.NewLedger(st)
	runtime := api.NewRuntime(api.RuntimeDependencies{
		Registry: registry.New(logger), Store: st, Ledger: ledger,
		ReadCache: readcache.New(), Logger: logger,
	}, api.ServerConfig{})
	t.Cleanup(runtime.Server.Close)
	ledger.RecordUsage("runtime-account", payments.UsageEntry{JobID: "shared-ledger", CostMicroUSD: 123})
	req := httptest.NewRequest(http.MethodGet, "/v1/payments/usage", nil)
	req.Header.Set("Authorization", "Bearer "+key)
	response := httptest.NewRecorder()
	runtime.Server.Handler().ServeHTTP(response, req)
	if response.Code != http.StatusOK {
		t.Fatalf("usage route = %d: %s", response.Code, response.Body.String())
	}
	var got types.UsageResponse
	if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Usage) != 1 || got.Usage[0].JobID != "shared-ledger" || got.Usage[0].CostMicroUSD != 123 {
		t.Fatalf("transport did not use the application ledger: %+v", got)
	}
}
