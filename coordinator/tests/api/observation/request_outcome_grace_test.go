package observation_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/observation"

	profile "github.com/eigeninference/d-inference/coordinator/internal/observation/profile"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestRequestOutcomeMissingTerminalGrace(t *testing.T) {
	t.Setenv(profile.EnvProfiler, "off")
	st := memory.NewMemory(store.Config{})
	s := production.New(production.Dependencies{Store: st, Logger: quietLogger(), ProfileFallbackGrace: 5 * time.Millisecond})
	t.Cleanup(s.Close)
	s.ObserveRequestOutcome(func(w http.ResponseWriter, r *http.Request) {
		rp := s.NewRequestProfile(r, "queued-model", "queued-model", false)
		ap := rp.NewAttempt("no-terminal", 0, "")
		ap.Mark(registry.StampWriteSubmitted)
		ap.Mark(registry.StampWriteDone)
		ap.CompleteHandler()
	})(httptest.NewRecorder(), httptest.NewRequest("POST", "/v1/completions", nil))
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		rows, err := st.RequestOutcomes(context.Background(), time.Time{}, time.Now(), 10)
		if err != nil {
			t.Fatal(err)
		}
		if len(rows) == 1 && rows[0].FinalizedAt != nil {
			r := rows[0]
			if r.Termination != "unknown" || r.EgressCompleted || len(r.Attempts) != 1 || r.Attempts[0].ProviderOutcome != "no_terminal" {
				t.Fatalf("grace fabricated result %+v", r)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("missing terminal grace did not finalize")
}
