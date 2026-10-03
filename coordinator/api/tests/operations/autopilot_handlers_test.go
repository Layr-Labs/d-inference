package operations_test

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
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
