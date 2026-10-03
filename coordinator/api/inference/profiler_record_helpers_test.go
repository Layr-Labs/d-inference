package inference

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// observedTestProfile retains the production finalizer while preserving the
// deliberately unstamped profile used by the lower-level lifecycle fixtures.
func observedTestProfile(t *testing.T, srv *Owner, start time.Time, id string) *registry.RequestProfile {
	t.Helper()
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	rp := srv.observation.NewRequestProfile(r, "", "", false)
	if rp == nil {
		t.Fatal("profile observation must be enabled for this fixture")
	}
	rp.T0, rp.CoordRequestID, rp.Endpoint = start, id, ""
	rp.HandlerEntryUS.Store(0)
	return rp
}

func awaitPersistedProfile(t *testing.T, srv *Owner, ap *registry.AttemptProfile) *store.RequestProfileRecord {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		rows := srv.store.RequestProfilesSinceFiltered(time.Time{}, store.RequestProfileFilter{CoordRequestID: ap.Parent().CoordRequestID})
		for _, row := range rows {
			if row.RequestID == ap.RequestID && row.Attempt == ap.Attempt {
				return &row
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("attempt %s/%d was not persisted", ap.RequestID, ap.Attempt)
		}
		time.Sleep(time.Millisecond)
	}
}
