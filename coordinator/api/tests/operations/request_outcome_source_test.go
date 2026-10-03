package operations_test

import (
	"context"
	"encoding/json"

	"net/http"
	"net/http/httptest"

	"testing"

	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestRequestOutcomeAdminBoundedSourceRoute(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{AdminKey: "outcome-admin"})
	st := fixture.Store
	ts := httptest.NewServer(fixture.Server.Handler())
	t.Cleanup(ts.Close)
	now := time.Now().Add(-time.Second)
	for _, id := range []string{"admin-a", "admin-b"} {
		if err := st.RecordRequestOutcomes(context.Background(), []store.RequestOutcomeRecord{{CoordRequestID: id, SchemaVersion: 1, Revision: 1, ReceivedAt: now, UpdatedAt: now, Endpoint: "/v1/messages", Termination: "in_progress", Attempts: []store.RequestAttemptOutcome{}}}); err != nil {
			t.Fatal(err)
		}
	}
	for _, auth := range []bool{false, true} {
		req, _ := http.NewRequest("GET", ts.URL+"/v1/admin/request-outcomes?limit=1", nil)
		if auth {
			req.Header.Set("Authorization", "Bearer outcome-admin")
		}
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		if !auth {
			res.Body.Close()
			if res.StatusCode < 400 {
				t.Fatal("unprotected registered admin route")
			}
			continue
		}
		var body struct {
			SchemaVersion int                          `json:"schema_version"`
			Count         int                          `json:"count"`
			Truncated     bool                         `json:"possibly_truncated"`
			Coverage      string                       `json:"coverage"`
			Data          []store.RequestOutcomeRecord `json:"data"`
		}
		err = json.NewDecoder(res.Body).Decode(&body)
		res.Body.Close()
		if err != nil || res.StatusCode != 200 || body.SchemaVersion != 1 || body.Count != 1 || !body.Truncated || body.Coverage != "observed_received_cohort" || len(body.Data) != 1 {
			t.Fatalf("bounded source status=%d body=%+v err=%v", res.StatusCode, body, err)
		}
	}
}
