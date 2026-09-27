package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// TestRoutingSaturatedShedRecordsNoServabilityWalk: a request shed because the
// routing-scan semaphore is saturated records its rejection without the
// telemetry worker walking the fleet. A servable provider exists, so a walk
// would have reported one candidate; the row must preserve unknown servability.
func TestRoutingSaturatedShedRecordsNoServabilityWalk(t *testing.T) {
	srv, reg, st, ts := setupTestServer(t)
	defer ts.Close()
	const model = "shed-walk-model"
	makeRoutableProvider(t, reg, "shed-walk-provider", model)
	if cc, _, _, _, _ := reg.QuickCapacityCheckWithTTFTForRequest(model, 10, 64, registry.RequestTraits{}, false); cc != 1 {
		t.Fatalf("fixture: candidate count for %s = %d, want 1 (a walk would find it)", model, cc)
	}

	// Saturate the semaphore from the test so the preflight sheds.
	srv.SetRoutingConcurrency(2)
	for i := 0; i < 2; i++ {
		if got := srv.acquireRoutingScanSlot(0, nil); got != scanSlotAcquired {
			t.Fatalf("slot %d: %v", i, got)
		}
	}
	defer func() {
		srv.releaseRoutingScanSlot()
		srv.releaseRoutingScanSlot()
	}()

	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hi"}],"max_tokens":64}`
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	out, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests || !strings.Contains(string(out), "routing capacity") {
		t.Fatalf("status = %d body = %s, want the routing_saturated 429", resp.StatusCode, out)
	}

	deadline := time.Now().Add(5 * time.Second)
	for {
		for _, rec := range st.RejectionRecordsSince(time.Now().Add(-time.Minute)) {
			if rec.ReasonCode != rejectionReasonRoutingSaturated {
				continue
			}
			if rec.CandidateCount != 0 || rec.CouldHaveServed != nil {
				t.Fatalf("shed rejection ran the counterfactual fleet walk: candidate_count=%d could_have_served=%v",
					rec.CandidateCount, rec.CouldHaveServed)
			}
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("routing_saturated rejection was never recorded")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
