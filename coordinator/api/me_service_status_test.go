package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestMyProvidersIncludesAccountScopedServiceStatus(t *testing.T) {
	srv, st := newKeyTestServer(t)
	seedProviderRecord(t, st, "owned", "SER-OWNED", "acct-1")
	live := srv.registry.Register("owned", nil, &protocol.RegisterMessage{})
	live.Mu().Lock()
	live.AccountID = "acct-1"
	live.Mu().Unlock()
	other := srv.registry.Register("other", nil, &protocol.RegisterMessage{})
	other.Mu().Lock()
	other.AccountID = "acct-2"
	other.Mu().Unlock()
	w := httptest.NewRecorder()
	srv.handleMyProviders(w, reqWithUser(http.MethodGet, "/v1/me/providers", "", "acct-1"))
	if w.Code != 200 {
		t.Fatalf("response %d: %s", w.Code, w.Body.String())
	}
	var response myProvidersResponse
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if len(response.Providers) != 1 {
		t.Fatalf("account returned %d providers", len(response.Providers))
	}
	status := response.Providers[0].ServiceStatus
	if status == nil || status.SchemaVersion != 1 || status.Probe.Scope != "public_text" || status.Reason != "no_models" || status.Models == nil {
		t.Fatalf("service snapshot missing/invalid: %+v", status)
	}
	if !status.ExpiresAt.After(status.ObservedAt) {
		t.Fatal("missing expiry")
	}
}

func TestMyProviderCapacitySnapshotDoesNotAliasSlots(t *testing.T) {
	srv, _ := newKeyTestServer(t)
	live := srv.registry.Register("node", nil, &protocol.RegisterMessage{})
	live.Mu().Lock()
	live.BackendCapacity = &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "model", State: "idle"}}}
	live.Mu().Unlock()
	snapshot := buildMyProvider(nil, live)
	live.Mu().Lock()
	live.BackendCapacity.Slots[0].State = "running"
	live.Mu().Unlock()
	if got := snapshot.BackendCapacity.Slots[0].State; got != "idle" {
		t.Fatalf("response aliases mutable registry slot: %s", got)
	}
}
