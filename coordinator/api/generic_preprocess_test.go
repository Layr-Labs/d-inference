package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// countingRegistryStore counts model-registry reads: the generic handler's
// body lowering reads the record once per lowering, so the count is the
// number of times the request body was lowered for the provider.
type countingRegistryStore struct {
	store.Store
	records atomic.Int64
}

func (c *countingRegistryStore) GetModelRegistryRecord(modelID string) (*store.ModelRegistryRecord, error) {
	c.records.Add(1)
	return c.Store.GetModelRegistryRecord(modelID)
}

// genericRegistryReadCeiling is the number of model-registry reads a
// /v1/completions or /v1/messages request pays up to admission on this tree
// (model resolution, runtime defaults, context lookup, the ONE body lowering
// in refreshGenericBody, and the admission preflight). The eager
// routingTraitsForModel(model) that preceded refreshGenericBody lowered the
// body once more — one extra read — only to be overwritten before anything
// read it; the base tree pays 7.
const genericRegistryReadCeiling = 6

// TestGenericInferenceLowersBodyOnceBeforeAdmission pins a ceiling on the
// registry reads (body lowerings) the generic handlers pay before admission.
func TestGenericInferenceLowersBodyOnceBeforeAdmission(t *testing.T) {
	inner := store.NewMemory(store.Config{AdminKey: "test-key"})
	cst := &countingRegistryStore{Store: inner}
	srv := NewServer(registry.New(quietLogger()), cst, ServerConfig{}, quietLogger())
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for _, endpoint := range []string{"/v1/completions", "/v1/messages"} {
		cst.records.Store(0)
		body := `{"model":"generic-model","prompt":"hi","max_tokens":8}`
		if endpoint == "/v1/messages" {
			body = `{"model":"generic-model","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+endpoint, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer test-key")
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("%s: %v", endpoint, err)
		}
		_, _ = io.ReadAll(resp.Body)
		resp.Body.Close()
		// No provider is registered, so the request ends at admission; every
		// lowering it paid happened before that.
		if resp.StatusCode < 400 {
			t.Fatalf("%s: status %d, want a no-provider rejection", endpoint, resp.StatusCode)
		}
		if got := cst.records.Load(); got > genericRegistryReadCeiling {
			t.Fatalf("%s: model-registry reads before admission = %d, want <= %d (the eager pre-admission lowering is dead work)", endpoint, got, genericRegistryReadCeiling)
		}
	}
}
