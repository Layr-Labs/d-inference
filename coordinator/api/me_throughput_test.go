package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// heartbeatTwoSlotProvider registers an account-owned live provider and drives
// ONE real heartbeat with two loaded slots — the active 27B measured slower
// than a co-resident MoE — so the tests exercise the ingest path
// (canonicalization, clamping) rather than hand-setting registry state.
// Registration deliberately carries no decode_tps/prefill_tps benchmark: that
// is what every current Swift provider sends.
func heartbeatTwoSlotProvider(t *testing.T, srv *Server, id, accountID string, measured bool) *registry.Provider {
	t.Helper()
	const active, other = "qwen3.8-27b-4bit-mtp", "qwen3.6-35b-a3b-vl-mtp-mxfp8"
	p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Hardware: protocol.Hardware{ChipName: "Apple M5 Max", ChipFamily: "M5", ChipTier: "Max", GPUCores: 40, MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: active}, {ID: other}},
	})
	if p == nil {
		t.Fatalf("provider %q did not register", id)
	}
	p.Mu().Lock()
	p.AccountID = accountID
	p.TrustLevel = registry.TrustHardware
	p.Attested = true
	p.Mu().Unlock()

	slots := []protocol.BackendSlotCapacity{
		{Model: other, State: "idle", NumRunning: 0},
		{Model: active, State: "running", NumRunning: 1},
	}
	if measured {
		slots[0].ObservedDecodeTPS, slots[0].ObservedPrefillTPS = 92.0, 3100
		slots[1].ObservedDecodeTPS, slots[1].ObservedPrefillTPS = 31.5, 1400
	}
	activeModel := active
	srv.registry.Heartbeat(id, &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "serving",
		ActiveModel: &activeModel,
		WarmModels:  []string{active, other},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB:     64,
			GPUMemoryActiveGB: 38.1,
			Slots:             slots,
		},
	})
	return p
}

type myProvidersThroughputResp struct {
	Providers []struct {
		ID         string   `json:"id"`
		DecodeTPS  *float64 `json:"decode_tps"`
		PrefillTPS *float64 `json:"prefill_tps"`
	} `json:"providers"`
}

func getMyProviders(t *testing.T, srv *Server, accountID string) (myProvidersThroughputResp, string) {
	t.Helper()
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, reqWithUser(http.MethodGet, "/v1/me/providers", "", accountID))
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp myProvidersThroughputResp
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(resp.Providers) != 1 {
		t.Fatalf("providers = %d, want 1: %s", len(resp.Providers), w.Body.String())
	}
	return resp, w.Body.String()
}

// TestMyProvidersThroughputFromHeartbeatSlots is the regression for the
// dashboard's permanently blank "Decode — tok/s": decode_tps/prefill_tps must
// come from the heartbeat's per-slot EWMA (active model first), not from the
// registration benchmark the Swift provider never sends.
func TestMyProvidersThroughputFromHeartbeatSlots(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	heartbeatTwoSlotProvider(t, srv, "p-live", "acct-1", true)

	resp, body := getMyProviders(t, srv, "acct-1")
	got := resp.Providers[0]
	if got.DecodeTPS == nil || *got.DecodeTPS != 31.5 {
		t.Fatalf("decode_tps = %v, want 31.5 (active slot EWMA): %s", got.DecodeTPS, body)
	}
	if got.PrefillTPS == nil || *got.PrefillTPS != 1400 {
		t.Fatalf("prefill_tps = %v, want 1400 (active slot EWMA): %s", got.PrefillTPS, body)
	}
}

// TestMyProvidersThroughputOmittedWhenUnmeasured pins the honest-blank
// contract: a connected machine that has not served a request omits both keys
// (omitempty) so the UI renders "—" rather than a fabricated zero or a
// bandwidth heuristic.
func TestMyProvidersThroughputOmittedWhenUnmeasured(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	heartbeatTwoSlotProvider(t, srv, "p-live", "acct-1", false)

	resp, body := getMyProviders(t, srv, "acct-1")
	if resp.Providers[0].DecodeTPS != nil || resp.Providers[0].PrefillTPS != nil {
		t.Fatalf("unmeasured provider reported throughput: %s", body)
	}
	if strings.Contains(body, `"decode_tps"`) || strings.Contains(body, `"prefill_tps"`) {
		t.Fatalf("unmeasured provider emitted throughput keys: %s", body)
	}
}

// TestStatsDecodeTPSFromHeartbeatSlots covers the public /v1/stats per-provider
// decode_tps, which shared the same dead registration-benchmark source.
func TestStatsDecodeTPSFromHeartbeatSlots(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	heartbeatTwoSlotProvider(t, srv, "p-live", "acct-1", true)

	rr := httptest.NewRecorder()
	srv.handleStats(rr, httptest.NewRequest(http.MethodGet, "/v1/stats", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", rr.Code, rr.Body.String())
	}
	var body struct {
		Providers []struct {
			ID        string  `json:"id"`
			DecodeTPS float64 `json:"decode_tps"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Providers) != 1 {
		t.Fatalf("providers = %d, want 1: %s", len(body.Providers), rr.Body.String())
	}
	if body.Providers[0].DecodeTPS != 31.5 {
		t.Fatalf("stats decode_tps = %v, want 31.5 (active slot EWMA)", body.Providers[0].DecodeTPS)
	}
}
