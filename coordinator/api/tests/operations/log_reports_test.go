package operations_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
)

func TestAdminLogReportSerialListRouteIsRemoved(t *testing.T) {
	srv := testkit.New(t, api.ServerConfig{}).Server
	srv.SetAdminKey("test-admin-key")
	req := httptest.NewRequest(http.MethodGet, "/v1/admin/log-reports?serial=PRIVATE-SERIAL", nil)
	req.Header.Set("Authorization", "Bearer test-admin-key")
	recorder := httptest.NewRecorder()

	srv.Handler().ServeHTTP(recorder, req)

	if recorder.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d; body=%s", recorder.Code, http.StatusNotFound, recorder.Body.String())
	}
	if strings.Contains(recorder.Body.String(), "PRIVATE-SERIAL") {
		t.Fatalf("removed route echoed device identity: %s", recorder.Body.String())
	}
}
