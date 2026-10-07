package operations_test

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
)

func TestAutopilotAdminEndpointRequiresAuthAndValidPause(t *testing.T) {
	f := testkit.New(t, api.ServerConfig{})
	srv := f.Server
	srv.SetAdminKey("autopilot-test-admin")
	if err := f.Registry.ConfigureAutopilot(autopilot.DefaultConfig()); err != nil {
		t.Fatal(err)
	}
	path := "/v1/admin/autopilot"
	if w := doReq(srv, http.MethodPost, path, "", `{"paused":true}`); w.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated=%d", w.Code)
	}
	auth := "Bearer autopilot-test-admin"
	if w := doReq(srv, http.MethodPost, path, auth, `{"paused":true}`); w.Code != http.StatusOK {
		t.Fatalf("pause=%d %s", w.Code, w.Body.String())
	}
	if !f.Registry.AutopilotSnapshot().Paused {
		t.Fatal("pause not applied")
	}
	if w := doReq(srv, http.MethodPost, path, auth, `{"paused":false}`); w.Code != http.StatusOK {
		t.Fatal(w.Code)
	}
	if f.Registry.AutopilotSnapshot().Paused {
		t.Fatal("resume not applied")
	}
}

func TestAutopilotAdminSummarySeparatesMachineCohortModes(t *testing.T) {
	const selected = "c2379b15-f532-45a9-a8c6-000000000001"
	const pausedSelected = "c2379b15-f532-45a9-a8c6-000000000002"
	const nonmember = "c2379b15-f532-45a9-a8c6-000000000003"
	f := testkit.New(t, api.ServerConfig{})
	f.Server.SetAdminKey("cohort-admin-key")
	cfg := autopilot.DefaultConfig()
	cfg.ObserveOnly, cfg.LiveMachineIDs = false, selected+","+pausedSelected
	if err := f.Registry.ConfigureAutopilot(cfg); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		id, machine               string
		paused, private, ordinary bool
	}{
		{id: "selected-session", machine: selected},
		{id: "paused-selected-session", machine: pausedSelected, paused: true},
		{id: "shadow-session", machine: nonmember},
		{id: "paused-unverified-session", paused: true},
		{id: "private-session", private: true},
		{id: "ordinary-session", ordinary: true},
	} {
		var state *protocol.ModelAutopilotState
		if !tc.ordinary {
			state = &protocol.ModelAutopilotState{Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true, Revision: "saved", SelectedModels: []string{"model"}, Paused: tc.paused}
		}
		p := f.Registry.Register(tc.id, nil, &protocol.RegisterMessage{ModelAutopilot: state, PrivateOnly: tc.private})
		p.Mu().Lock()
		p.AccountID = "private-owner"
		p.Mu().Unlock()
		if tc.machine != "" && !f.Registry.BindVerifiedMachineIdentity(p, "private-owner", tc.machine) {
			t.Fatal("verified machine fixture rejected")
		}
	}
	// Registration-only, paused and stale connections remain mode coverage;
	// none has the live acknowledgement or fresh capacity needed for mutation.
	f.Registry.TriggerAutopilot()
	server := httptest.NewServer(f.Server.Handler())
	t.Cleanup(server.Close)
	req, err := http.NewRequest(http.MethodGet, server.URL+"/v1/admin/autopilot", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer cohort-admin-key")
	response, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("admin response status=%d body=%s error=%v", response.StatusCode, body, err)
	}
	var result struct {
		Summary autopilot.Summary `json:"summary"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	summary := result.Summary
	if !summary.Enabled || summary.ObserveOnly || summary.LiveCohort != 2 || summary.LiveActive != 0 || summary.Shadow != 2 || summary.LiveProposed != 0 || summary.ShadowProposed != 0 || summary.Proposed != 0 || summary.Issued != 0 {
		t.Fatalf("mode coverage was confused with current control or eligibility: %+v", summary)
	}
	for _, field := range []string{"live_cohort", "live_active", "shadow", "live_proposed", "shadow_proposed"} {
		if !strings.Contains(string(body), `"`+field+`":`) {
			t.Fatalf("zero-valued diagnostic %s was omitted", field)
		}
	}
	for _, private := range []string{selected, pausedSelected, nonmember, "private-owner", "selected-session", "shadow-session"} {
		if strings.Contains(string(body), private) {
			t.Fatalf("aggregate mode diagnostics expose identity %q", private)
		}
	}
	if response := doReq(f.Server, http.MethodPost, "/v1/admin/autopilot", "Bearer cohort-admin-key", `{"paused":false,"live_machine_ids":"`+nonmember+`"}`); response.Code != http.StatusBadRequest {
		t.Fatal("admin pause endpoint accepted a runtime cohort change")
	}
}
