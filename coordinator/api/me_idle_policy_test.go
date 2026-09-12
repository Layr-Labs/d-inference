package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// The owner's dashboard needs the idle-memory policy to render a missing
// slot as "sleeping, wakes on demand" (free-when-idle) rather than as a
// warning. The heartbeat value is surfaced per live machine; 0 (always
// ready) must not be collapsed into "absent".
func TestMyProvidersSurfacesIdleUnloadPolicy(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "live-p", "SER-IDLE", "acct-1")

	// A linked, attested live connection — heartbeats persist the live
	// provider back to the store, so it must carry the owner's account.
	live := srv.registry.Register("live-p", nil, &protocol.RegisterMessage{})
	live.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "SER-IDLE"})
	live.Mu().Lock()
	live.AccountID = "acct-1"
	live.Mu().Unlock()

	fetch := func(stage string) map[string]any {
		t.Helper()
		r := reqWithUser(http.MethodGet, "/v1/me/providers", "", "acct-1")
		w := httptest.NewRecorder()
		srv.handleMyProviders(w, r)
		if w.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
		}
		var resp struct {
			Providers []map[string]any `json:"providers"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("decode: %v", err)
		}
		for _, p := range resp.Providers {
			if p["id"] == "live-p" {
				return p
			}
		}
		t.Fatalf("[%s] live-p missing from response: %s", stage, w.Body.String())
		return nil
	}

	// Before any heartbeat reports a policy: omitted, not defaulted.
	if _, ok := fetch("initial")["idle_unload_mins"]; ok {
		t.Fatal("idle_unload_mins present before the provider reported one")
	}

	zero := 0
	srv.registry.Heartbeat("live-p", &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", IdleUnloadMins: &zero,
	})
	if got := fetch("zero")["idle_unload_mins"]; got != float64(0) {
		t.Fatalf("idle_unload_mins = %v, want 0 (always ready)", got)
	}

	sixty := 60
	srv.registry.Heartbeat("live-p", &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", IdleUnloadMins: &sixty,
	})
	if got := fetch("sixty")["idle_unload_mins"]; got != float64(60) {
		t.Fatalf("idle_unload_mins = %v, want 60", got)
	}

	// A legacy-shaped heartbeat (no field) keeps the last reported policy.
	srv.registry.Heartbeat("live-p", &protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
	})
	if got := fetch("legacy")["idle_unload_mins"]; got != float64(60) {
		t.Fatalf("idle_unload_mins after legacy heartbeat = %v, want 60 (sticky)", got)
	}
}
