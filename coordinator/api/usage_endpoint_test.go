package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
)

// TestUsageEndpointServesBoundedWindow: after many completions the endpoint
// returns the newest 100 session entries with their fields intact.
func TestUsageEndpointServesBoundedWindow(t *testing.T) {
	srv, _, ledger := billingTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	for i := 0; i < 250; i++ {
		ledger.RecordUsage(testConsumerID, payments.UsageEntry{
			JobID: fmt.Sprintf("job-%d", i), Model: "usage-model", PromptTokens: 10, CompletionTokens: 20,
			CostMicroUSD: int64(i), Timestamp: time.Now(),
		})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/v1/payments/usage", nil)
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET usage: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var out types.UsageResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(out.Usage) != 100 {
		t.Fatalf("usage entries = %d, want the bounded 100", len(out.Usage))
	}
	if first, last := out.Usage[0], out.Usage[99]; first.JobID != "job-150" || last.JobID != "job-249" || last.CostMicroUSD != 249 || last.Model != "usage-model" {
		t.Fatalf("window = %s..%s (last cost %d, model %s), want job-150..job-249", first.JobID, last.JobID, last.CostMicroUSD, last.Model)
	}
}
