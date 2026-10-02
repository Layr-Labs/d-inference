package autopilot

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	policy "github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type testController struct {
	configured, paused bool
}

func (c *testController) SetAutopilotPaused(paused bool) bool {
	if !c.configured {
		return false
	}
	c.paused = paused
	return true
}
func (c *testController) AutopilotSnapshot() policy.Summary { return policy.Summary{Paused: c.paused} }

func TestPauseRejectsMalformedOrTrailingInputWithoutMutation(t *testing.T) {
	for _, body := range []string{`{}`, `{"paused":"yes"}`, `{"paused":true,"extra":1}`, `{"paused":true} {}`} {
		c := &testController{configured: true}
		w := httptest.NewRecorder()
		Handler{Controller: c}.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body)))
		var response struct {
			Error struct{ Type, Code, Message string }
		}
		if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if w.Code != http.StatusBadRequest || c.paused || response.Error.Type != "invalid_request_error" || response.Error.Code != response.Error.Type {
			t.Fatalf("body=%s status=%d response=%s paused=%v", body, w.Code, w.Body.String(), c.paused)
		}
	}
}

func TestUnconfiguredControllerRejectsMutation(t *testing.T) {
	w := httptest.NewRecorder()
	Handler{Controller: &testController{}}.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"paused":true}`)))
	if w.Code != http.StatusConflict {
		t.Fatalf("status=%d", w.Code)
	}
}

type failedLedger struct{ store.AutopilotStore }

func (failedLedger) AutopilotRecords(context.Context, time.Time, int) ([]store.AutopilotRecord, error) {
	return nil, errors.New("test unavailable")
}

func TestStatusReturnsDurableEventsAndDoesNotHideLedgerFailure(t *testing.T) {
	ledger := store.NewMemory(store.Config{})
	if err := ledger.RecordAutopilot(context.Background(), []store.AutopilotRecord{{CommandID: "command", Phase: "reserved", At: time.Now()}}); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		ledger store.AutopilotStore
		status int
	}{
		{"available", ledger, http.StatusOK}, {"unavailable", failedLedger{}, http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			Handler{Controller: &testController{configured: true}, Ledger: tc.ledger}.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/", nil))
			if w.Code != tc.status {
				t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
			}
			if tc.status == http.StatusOK {
				var response struct{ Events []store.AutopilotRecord }
				if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
					t.Fatal(err)
				}
				if len(response.Events) != 1 || response.Events[0].CommandID != "command" {
					t.Fatalf("events=%+v", response.Events)
				}
			}
		})
	}
}
